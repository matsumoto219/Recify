class ReceiptAnalysisPipeline
  LOG_TAG = "[ReceiptAnalysisPipeline]".freeze
  FINALIZE_DECISION_SCHEMA_VERSION = "receipt_analysis_run_finalize_decision_v1"
  FINALIZE_STRATEGIES = %w[fail_receipt ocr_only ai_fallback ai_success].freeze

  class AnalysisError < StandardError
    attr_reader :error_code

    def initialize(error_code, message = nil)
      @error_code = error_code
      super(message)
    end
  end

  class << self
    def run_ocr(run)
      new(run).run_ocr
    end

    def run_ai(run_arg = nil, run: nil, ocr_result: nil, ai_name_completion_enabled: nil)
      new(run || run_arg).run_ai(
        ocr_result: ocr_result,
        ai_name_completion_enabled: ai_name_completion_enabled
      )
    end

    def run_finalize(run)
      new(run).run_finalize
    end

    def finalize(receipt:, decision:, run: nil)
      FinalizeStep.call(receipt: receipt, decision: decision, run: run)
    end

    def finalize_decision_from_snapshot(snapshot)
      FinalizeDecision.from_snapshot(snapshot)
    end
  end

  def initialize(run)
    @run = run
    @receipt = run.receipt
  end

  def run_ocr
    return skipped_result(:terminal_run) if terminal_run?
    return cancel_and_skip(:not_processing) unless receipt.processing?
    return usage_limit_blocked_result("ocr") unless ocr_provider_call_allowed?

    with_run_failure do
      mark_processing!
      ReceiptAnalysisRuns.start_stage(run, "ocr")
      ocr_result = OcrStep.call(run).ocr_result
      log_ocr_result(ocr_result)

      decision = ocr_finalize_decision(ocr_result)
      decision ||= ai_gate_finalize_decision(ocr_result)

      if decision
        record_finalize_decision(decision)
        Result.new(
          ocr_result: ocr_result,
          finalize_decision: decision,
          next_step: :finalize
        )
      else
        Result.new(
          ocr_result: ocr_result,
          next_step: :ai
        )
      end
    end
  end

  def run_ai(ocr_result: nil, ai_name_completion_enabled: nil)
    return skipped_result(:terminal_run) if terminal_run?
    return cancel_and_skip(:not_processing) unless receipt.processing?

    with_run_failure do
      ocr_result ||= ocr_result_from_snapshot
      return fail_missing_snapshot!("ocr_result_snapshot_missing", error_stage: "ai") if ocr_result.blank?

      decision = ai_gate_finalize_decision(ocr_result)
      if decision
        record_finalize_decision(decision)
        return Result.new(
          ocr_result: ocr_result,
          finalize_decision: decision,
          next_step: :finalize
        )
      end

      return usage_limit_blocked_result("ai") unless ai_provider_call_allowed?

      raw_ai_result = AiStep.call(
        run: run,
        ocr_result: ocr_result,
        ai_name_completion_enabled: ai_name_completion_enabled.nil? ? ai_name_completion_enabled? : ai_name_completion_enabled
      ).ai_result
      ai_result = normalize_ai_result(raw_ai_result)
      log_ai_result(ai_result)

      decision = ai_finalize_decision(ocr_result, ai_result)
      record_finalize_decision(decision)

      Result.new(
        ocr_result: ocr_result,
        ai_result: ai_result,
        finalize_decision: decision,
        next_step: :finalize
      )
    end
  end

  def run_finalize
    return skipped_result(:terminal_run) if terminal_run?
    return cancel_and_skip(:not_processing) unless receipt.processing?

    with_run_failure do
      decision = finalize_decision_from_run
      return fail_missing_snapshot!("finalize_decision_missing", error_stage: "finalize") unless decision

      self.class.finalize(receipt: receipt, decision: decision, run: run)
      receipt.reload
      ReceiptAnalysisRuns.record_final_result(run, receipt: receipt)
      ReceiptAnalysisRuns.succeed(run)

      Result.new(
        finalize_decision: decision,
        next_step: :done
      )
    end
  end

  private

  attr_reader :run, :receipt

  def terminal_run?
    !ReceiptAnalysisRun::ACTIVE_STATUSES.include?(run.status)
  end

  def cancel_active_run
    return unless run.active?

    ReceiptAnalysisRuns.cancel(run)
  rescue ReceiptAnalysisRuns::TerminalRunError
    nil
  end

  def cancel_and_skip(reason)
    cancel_active_run
    Rails.logger.info(
      "#{LOG_TAG} skipped receipt_id=#{receipt.id} run_id=#{run.id} status=#{receipt.status} reason=#{reason}"
    )
    skipped_result(reason)
  end

  def skipped_result(reason)
    Rails.logger.info(
      "#{LOG_TAG} skipped receipt_id=#{receipt.id} run_id=#{run.id} status=#{run.status} reason=#{reason}"
    ) if reason == :terminal_run

    Result.new(next_step: :skipped, skip_reason: reason)
  end

  def with_run_failure
    yield
  rescue => e
    fail_run(e)
    raise
  end

  def mark_processing!
    receipt.update!(
      status: "processing",
      processing_error_code: nil,
      processing_error_message: nil,
      review_reasons: []
    )
  end

  def log_ocr_result(ocr_result)
    Rails.logger.info(
      "[ReceiptAnalysis] ocr_result receipt_id=#{receipt.id} success=#{ocr_result[:success]} lines=#{ocr_result[:lines]&.size || 0} error_code=#{ocr_result[:error_code]}"
    )
  end

  def log_ai_result(ai_result)
    Rails.logger.info(
      "[ReceiptAnalysis] ai_result receipt_id=#{receipt.id} success=#{ai_result[:success]} error_code=#{ai_result[:error_code]}"
    )
  end

  def ocr_finalize_decision(ocr_result)
    unless ocr_result[:success]
      return finalize_decision(
        :fail_receipt,
        ocr_result: ocr_result,
        error_code: ocr_result[:error_code].presence || "ocr_api_error"
      )
    end

    if unsupported_country?(ocr_result)
      country_code = ocr_country_region(ocr_result)
      Rails.logger.warn("[ReceiptAnalysis] unsupported_country receipt_id=#{receipt.id} country_region=#{country_code}")
      return finalize_decision(
        :fail_receipt,
        ocr_result: ocr_result,
        error_code: "unsupported_country",
        error_message: "country_region=#{country_code}",
        receipt_attributes: unsupported_country_attributes(country_code)
      )
    end

    receipt_signal = Analysis::ReceiptSignalEvaluator.call(ocr_result)

    if no_text_detected?(receipt_signal)
      Rails.logger.warn("[ReceiptAnalysis] no_text_detected receipt_id=#{receipt.id}")
      return finalize_decision(:fail_receipt, ocr_result: ocr_result, error_code: "no_text_detected")
    end

    if unreadable_ocr?(ocr_result)
      Rails.logger.warn("[ReceiptAnalysis] ocr_unreadable receipt_id=#{receipt.id}")
      return finalize_decision(:fail_receipt, ocr_result: ocr_result, error_code: "ocr_unreadable")
    end

    if receipt_structure_missing?(receipt_signal)
      Rails.logger.warn(
        "[ReceiptAnalysis] receipt_not_detected receipt_id=#{receipt.id} score=#{receipt_signal.score} reasons=#{receipt_signal.reasons.join(',')}"
      )
      return finalize_decision(:fail_receipt, ocr_result: ocr_result, error_code: "receipt_not_detected")
    end

    nil
  end

  def ai_gate_finalize_decision(ocr_result)
    unless ai_enabled?
      Rails.logger.info("[ReceiptAnalysis] ai_disabled_ocr_only receipt_id=#{receipt.id}")
      return finalize_decision(:ocr_only, ocr_result: ocr_result)
    end

    unless ai_available?
      Rails.logger.info("[ReceiptAnalysis] ai_down_ocr_only receipt_id=#{receipt.id}")
      return finalize_decision(:ai_fallback, ocr_result: ocr_result, error_code: "ai_unavailable")
    end

    nil
  end

  def ai_finalize_decision(ocr_result, ai_result)
    if ai_result[:success]
      finalize_decision(:ai_success, ocr_result: ocr_result, ai_result: ai_result)
    elsif ai_not_receipt?(ai_result)
      Rails.logger.warn(
        "[ReceiptAnalysis] ai_not_receipt receipt_id=#{receipt.id} document_type=#{ai_result.dig(:meta, :document_type)} rejection_reason=#{ai_result.dig(:meta, :rejection_reason)} confidence=#{ai_result.dig(:meta, :is_receipt_confidence)}"
      )
      ai_not_receipt_decision(ocr_result, ai_result)
    else
      finalize_decision(
        :ai_fallback,
        ocr_result: ocr_result,
        ai_result: ai_result,
        error_code: ai_result[:error_code].presence || "ai_invalid_response",
        error_message: ai_fallback_processing_error_message(ai_result)
      )
    end
  end

  def finalize_decision(finalize_strategy, ocr_result: nil, ai_result: nil, error_code: nil, error_message: nil, receipt_attributes: {}, metadata: {})
    FinalizeDecision.new(
      finalize_strategy: finalize_strategy.to_s,
      error_code: error_code,
      error_message: error_message,
      receipt_attributes: receipt_attributes || {},
      ocr_result: ocr_result,
      ai_result: ai_result,
      metadata: metadata || {}
    )
  end

  def record_finalize_decision(decision)
    ReceiptAnalysisRuns.record_finalize_decision(run, decision)
  end

  def finalize_decision_from_run
    self.class.finalize_decision_from_snapshot(run.metadata.to_h["finalize_decision"])
  end

  def ocr_result_from_snapshot
    snapshot = normalized_hash(run.ocr_result_snapshot)
    return nil if snapshot.blank?

    {
      success: snapshot[:success] == true,
      lines: Array(snapshot[:lines]).map(&:to_s),
      candidates: normalized_hash(snapshot[:candidates]).to_h,
      error_code: snapshot[:error_code].presence,
      meta: normalized_hash(snapshot[:meta]).to_h
    }.compact
  end

  def fail_missing_snapshot!(error_code, error_stage:)
    ReceiptAnalysisRuns.fail(
      run,
      error_stage: error_stage,
      error_code: error_code,
      error_message: error_code
    )
    Result.new(next_step: :skipped, skip_reason: error_code.to_sym)
  rescue ReceiptAnalysisRuns::TerminalRunError
    Result.new(next_step: :skipped, skip_reason: :terminal_run)
  end

  def ocr_provider_call_allowed?
    UsageLimits.ensure_ocr_job_within_limit!(user: receipt.user)
    true
  rescue UsageLimits::LimitExceeded
    false
  end

  def ai_provider_call_allowed?
    UsageLimits.consume_ai_job!(user: receipt.user)
    true
  rescue UsageLimits::LimitExceeded
    false
  end

  def usage_limit_blocked_result(stage)
    UsageLimits.mark_analysis_run_blocked!(run: run, stage: stage)
    Result.new(next_step: :skipped, skip_reason: :usage_limit_exceeded)
  end

  def ai_name_completion_enabled?
    receipt.user&.product_name_ai_completion_enabled == true
  end

  def ai_enabled?
    ActiveModel::Type::Boolean.new.cast(
      ENV.fetch(Config::AI_ENABLED_ENV_KEY, "true")
    )
  end

  def ai_available?
    !ExternalServiceStatus.down?(:ai)
  end

  def normalize_ai_result(result)
    return { success: false, error_code: "ai_invalid_response" } unless result.is_a?(Hash)

    symbolized = result.symbolize_keys

    if symbolized[:success] == false
      return {
        success: false,
        error_code: symbolized[:error_code].presence || "ai_invalid_response",
        needs_review: symbolized[:needs_review],
        review_reasons: Array(symbolized[:review_reasons]),
        meta: normalize_ai_meta(symbolized[:meta])
      }
    end

    unless symbolized[:receipt_attributes].is_a?(Hash)
      return { success: false, error_code: "ai_invalid_response" }
    end

    symbolized[:receipt_items_attributes] ||= []

    {
      success: symbolized.key?(:success) ? symbolized[:success] : true,
      error_code: symbolized[:error_code],
      needs_review: symbolized[:needs_review],
      review_reasons: Array(symbolized[:review_reasons]),
      receipt_attributes: symbolized[:receipt_attributes].symbolize_keys,
      receipt_items_attributes: Analysis::ReceiptItemNormalizer.normalize_ai_items(
        symbolized[:receipt_items_attributes]
      ),
      meta: normalize_ai_meta(symbolized[:meta])
    }
  end

  def normalize_ai_meta(meta)
    return {} unless meta.is_a?(Hash)

    meta.deep_symbolize_keys
  end

  def unsupported_country?(ocr_result)
    country_code = ocr_country_region(ocr_result)
    country_code.present? && !Config::SUPPORTED_RECEIPT_COUNTRY_CODES.include?(country_code)
  end

  def ocr_country_region(ocr_result)
    candidates = ocr_candidates(ocr_result)
    normalize_country_region(candidates[:country_region])
  end

  def normalize_country_region(value)
    value.to_s.strip.upcase.presence
  end

  def unsupported_country_attributes(country_code)
    return {} unless country_code.to_s.length == 3

    { country_region: country_code }
  end

  def no_text_detected?(receipt_signal)
    !receipt_signal.text_present
  end

  def unreadable_ocr?(ocr_result)
    candidates = ocr_candidates(ocr_result)
    overall_confidence = candidates.dig(:confidence_summary, :overall)

    return true if overall_confidence.present? && overall_confidence.to_f < Config::UNREADABLE_CONFIDENCE_THRESHOLD

    false
  end

  def receipt_structure_missing?(receipt_signal)
    !receipt_signal.receipt_like?
  end

  def ai_not_receipt?(ai_result)
    ai_result[:error_code].to_s == "ai_not_receipt"
  end

  def ai_not_receipt_message(ai_result)
    meta = ai_result[:meta].is_a?(Hash) ? ai_result[:meta].symbolize_keys : {}
    [ meta[:document_type], meta[:rejection_reason] ].compact_blank.join(" / ").presence || "ai_not_receipt"
  end

  def ai_not_receipt_decision(ocr_result, ai_result)
    receipt_signal = Analysis::ReceiptSignalEvaluator.call(ocr_result)

    if ai_not_receipt_should_fail?(ai_result, receipt_signal)
      finalize_decision(
        :fail_receipt,
        ocr_result: ocr_result,
        ai_result: ai_result,
        error_code: "ai_not_receipt",
        error_message: ai_not_receipt_message(ai_result)
      )
    else
      Rails.logger.warn(
        "[ReceiptAnalysis] ai_not_receipt_uncertain receipt_id=#{receipt.id} score=#{receipt_signal.score} reasons=#{receipt_signal.reasons.join(',')}"
      )
      finalize_decision(
        :ai_fallback,
        ocr_result: ocr_result,
        ai_result: ai_result,
        error_code: "ai_not_receipt_uncertain"
      )
    end
  end

  def ai_not_receipt_should_fail?(ai_result, receipt_signal)
    confidence = ai_receipt_confidence(ai_result)
    return false if confidence.blank? || confidence < 0.5
    return false if ocr_strong_receipt_evidence?(receipt_signal)

    true
  end

  def ai_receipt_confidence(ai_result)
    meta = ai_result[:meta].is_a?(Hash) ? ai_result[:meta].symbolize_keys : {}
    value = meta[:is_receipt_confidence]
    return nil if value.blank?

    Float(value)
  rescue ArgumentError, TypeError
    nil
  end

  def ocr_strong_receipt_evidence?(receipt_signal)
    reasons = Array(receipt_signal.reasons).map(&:to_sym)

    return true if reasons.include?(:tax_details)
    return true if reasons.include?(:payments)
    return true if reasons.include?(:receipt_amount_context_line)
    return true if reasons.include?(:receipt_word) && reasons.include?(:receipt_amount_context_line)

    reasons.include?(:valid_items) &&
      (reasons & %i[total_amount payments payment_method_text tax_details receipt_amount_context_line]).any?
  end

  def ai_fallback_processing_error_message(ai_result)
    return unless ai_result.is_a?(Hash)

    meta = ai_result[:meta].is_a?(Hash) ? ai_result[:meta].symbolize_keys : {}
    return if meta.blank?

    provider = meta[:fallback_provider].presence || meta[:primary_provider].presence
    error_code = meta[:fallback_error_code].presence ||
      meta[:primary_error_code].presence ||
      ai_result[:error_code].presence
    raw_message = meta[:fallback_error_message].presence || meta[:primary_error_message].presence
    reason = ai_fallback_reason(raw_message)

    details = []
    details << "provider=#{provider}" if provider.present?
    details << "code=#{error_code}" if error_code.present?
    details << "reason=#{reason}" if reason.present?

    return if details.blank?

    "AI補完に失敗したためOCR結果で保存しました (#{details.join(', ')})"
  end

  def ai_fallback_reason(raw_message)
    message = raw_message.to_s
    return "timeout" if message.match?(/timeout|timed out|read timeout|execution expired/i)
    return "rate_limit" if message.match?(/rate limit|too many requests|\b429\b/i)
    return "invalid_response" if message.match?(/invalid response|invalid json|parse/i)

    "provider_error"
  end

  def ocr_candidates(ocr_result)
    (ocr_result[:candidates] || {}).deep_symbolize_keys
  end

  def normalized_hash(value)
    return value.with_indifferent_access if value.respond_to?(:with_indifferent_access)

    {}.with_indifferent_access
  end

  def fail_run(error)
    ReceiptAnalysisRuns.fail(
      run,
      error_stage: run.stage.presence || "ocr",
      error_code: error_code_for(error),
      error_message: error.message
    )
  rescue ReceiptAnalysisRuns::TerminalRunError
    nil
  end

  def error_code_for(error)
    return error.error_code if error.respond_to?(:error_code) && error.error_code.present?

    "unexpected_error"
  end
end
