class ReceiptAnalysisService
  def self.call(receipt, run: nil, ocr_result: nil)
    new(receipt, run: run, ocr_result: ocr_result).call
  end

  def initialize(receipt, run: nil, ocr_result: nil)
    @receipt = receipt
    @run = run
    @ocr_result = ocr_result
  end

  def call
    Rails.logger.info("[ReceiptAnalysis] start receipt_id=#{receipt.id}")

    mark_processing!

    unless ocr_enabled?
      Rails.logger.warn("[ReceiptAnalysis] ocr_disabled receipt_id=#{receipt.id}")
      return finalize(finalize_decision(:fail_receipt, error_code: "ocr_disabled"))
    end

    ocr_result = provided_ocr_result? ? @ocr_result : ReceiptOcrService.call(receipt.image)
    log_ocr_result(ocr_result)
    record_ocr_result(ocr_result) unless provided_ocr_result?

    unless ocr_result[:success]
      return finalize(
        finalize_decision(
          :fail_receipt,
          ocr_result: ocr_result,
          error_code: ocr_result[:error_code].presence || "ocr_api_error"
        )
      )
    end

    if unsupported_country?(ocr_result)
      country_code = ocr_country_region(ocr_result)
      Rails.logger.warn("[ReceiptAnalysis] unsupported_country receipt_id=#{receipt.id} country_region=#{country_code}")
      return finalize(
        finalize_decision(
          :fail_receipt,
          ocr_result: ocr_result,
          error_code: "unsupported_country",
          error_message: "country_region=#{country_code}",
          receipt_attributes: unsupported_country_attributes(country_code)
        )
      )
    end

    receipt_signal = Analysis::ReceiptSignalEvaluator.call(ocr_result)

    if no_text_detected?(receipt_signal)
      Rails.logger.warn("[ReceiptAnalysis] no_text_detected receipt_id=#{receipt.id}")
      return finalize(finalize_decision(:fail_receipt, ocr_result: ocr_result, error_code: "no_text_detected"))
    end

    if unreadable_ocr?(ocr_result)
      Rails.logger.warn("[ReceiptAnalysis] ocr_unreadable receipt_id=#{receipt.id}")
      return finalize(finalize_decision(:fail_receipt, ocr_result: ocr_result, error_code: "ocr_unreadable"))
    end

    if receipt_structure_missing?(receipt_signal)
      Rails.logger.warn(
        "[ReceiptAnalysis] receipt_not_detected receipt_id=#{receipt.id} score=#{receipt_signal.score} reasons=#{receipt_signal.reasons.join(',')}"
      )
      return finalize(finalize_decision(:fail_receipt, ocr_result: ocr_result, error_code: "receipt_not_detected"))
    end

    unless ai_enabled?
      Rails.logger.info("[ReceiptAnalysis] ai_disabled_ocr_only receipt_id=#{receipt.id}")
      return finalize(finalize_decision(:ocr_only, ocr_result: ocr_result))
    end

    unless ai_available?
      Rails.logger.info("[ReceiptAnalysis] ai_down_ocr_only receipt_id=#{receipt.id}")
      return finalize(finalize_decision(:ai_fallback, ocr_result: ocr_result, error_code: "ai_unavailable"))
    end

    ai_result = run_ai_enrichment(ocr_result)

    if ai_result[:success]
      finalize(finalize_decision(:ai_success, ocr_result: ocr_result, ai_result: ai_result))
    elsif ai_not_receipt?(ai_result)
      Rails.logger.warn(
        "[ReceiptAnalysis] ai_not_receipt receipt_id=#{receipt.id} document_type=#{ai_result.dig(:meta, :document_type)} rejection_reason=#{ai_result.dig(:meta, :rejection_reason)} confidence=#{ai_result.dig(:meta, :is_receipt_confidence)}"
      )
      finalize(ai_not_receipt_decision(ocr_result, ai_result, receipt_signal))
    else
      finalize(
        finalize_decision(
          :ai_fallback,
          ocr_result: ocr_result,
          ai_result: ai_result,
          error_code: ai_result[:error_code].presence || "ai_invalid_response",
          error_message: ai_fallback_processing_error_message(ai_result)
        )
      )
    end
  rescue ReceiptAnalysisPipeline::AnalysisError
    raise
  rescue StandardError => e
    Rails.logger.error(
      "[ReceiptAnalysis] unexpected_error receipt_id=#{receipt.id} error_class=#{e.class} error_code=unexpected_error"
    )
    finalize(finalize_decision(:fail_receipt, error_code: "unexpected_error", error_message: e.message))
    # NOTE: 想定外エラーはReceipt側にfailed保存したうえでAnalysisErrorを再raiseする。
    # Job retryは行わず、再解析や手動修正はユーザー操作に委ねる方針。
    raise ReceiptAnalysisPipeline::AnalysisError.new("unexpected_error", e.message)
  end

  private

  attr_reader :receipt, :run

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

  def provided_ocr_result?
    !@ocr_result.nil?
  end

  def ocr_enabled?
    ActiveModel::Type::Boolean.new.cast(
      ENV.fetch(ReceiptAnalysisPipeline::Config::OCR_ENABLED_ENV_KEY, "true")
    )
  end

  def ai_enabled?
    ActiveModel::Type::Boolean.new.cast(
      ENV.fetch(ReceiptAnalysisPipeline::Config::AI_ENABLED_ENV_KEY, "true")
    )
  end

  def ai_available?
    !ExternalServiceStatus.down?(:ai)
  end

  def run_ai_enrichment(ocr_result)
    ai_result =
      if run
        ReceiptAnalysisPipeline.run_ai(
          run: run,
          ocr_result: ocr_result,
          ai_name_completion_enabled: ai_name_completion_enabled?
        ).ai_result
      else
        ReceiptAiEnrichmentService.call(
          ocr_result,
          ai_name_completion_enabled: ai_name_completion_enabled?,
          capture_input: nil
        )
      end
    normalized = normalize_ai_result(ai_result)

    Rails.logger.info(
      "[ReceiptAnalysis] ai_result receipt_id=#{receipt.id} success=#{normalized[:success]} error_code=#{normalized[:error_code]}"
    )

    normalized
    # rescue ReceiptAiEnrichmentService::AiEnrichmentError => e
    #   Rails.logger.warn(
    #     "[ReceiptAnalysis] ai_failed_fallback receipt_id=#{receipt.id} error_code=#{e.error_code} message=#{e.message}"
    #   )
    #   { success: false, error_code: e.error_code }
    # end
    #
    # ReceiptAiEnrichmentService は現在、例外をそのまま上げず ResultTemplate.error を返す設計へ寄せている。
    # そのためこの rescue は現状ほぼ通らないが、直前の挙動との差分確認用に一旦コメントで残す。
  end

  def record_ocr_result(ocr_result)
    return unless run

    ReceiptAnalysisRuns.record_ocr_result(run, ocr_result)
  end

  def finalize_decision(finalize_strategy, ocr_result: nil, ai_result: nil, error_code: nil, error_message: nil, receipt_attributes: {}, metadata: {})
    ReceiptAnalysisPipeline::FinalizeDecision.new(
      finalize_strategy: finalize_strategy.to_s,
      error_code: error_code,
      error_message: error_message,
      receipt_attributes: receipt_attributes || {},
      ocr_result: ocr_result,
      ai_result: ai_result,
      metadata: metadata || {}
    )
  end

  def finalize(decision)
    record_finalize_decision(decision)
    ReceiptAnalysisPipeline.finalize(receipt: receipt, decision: decision, run: run)
  end

  def record_finalize_decision(decision)
    return unless run

    ReceiptAnalysisRuns.record_finalize_decision(run, decision)
  end

  # 商品名AI補完
  def ai_name_completion_enabled?
    receipt.user&.product_name_ai_completion_enabled == true
  end

  def normalize_ai_result(result)
    # NOTE:
    # AI 共通の item 正規化は Analysis::ReceiptItemNormalizer に寄せ、
    # ReceiptAnalysisService では success / error の判定と全体フロー制御を主責務とする。

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

    # success系は receipt_attributes を含む構造のみ受け付ける
    unless symbolized[:receipt_attributes].is_a?(Hash)
      return { success: false, error_code: "ai_invalid_response" }
    end

    # receipt_items_attributes が無い場合は空配列で扱う
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

  def unreadable_ocr?(ocr_result)
    candidates = ocr_candidates(ocr_result)
    overall_confidence = candidates.dig(:confidence_summary, :overall)
    # TODO: 実レスポンスで confidence_summary の配置を再確認する。
    # 現在は candidates 配下を参照しているが、meta 配下に入る可能性もあるため、
    # API実レスポンス確認後に参照先を一本化する。

    return true if overall_confidence.present? && overall_confidence.to_f < ReceiptAnalysisPipeline::Config::UNREADABLE_CONFIDENCE_THRESHOLD

    false
  end

  def unsupported_country?(ocr_result)
    country_code = ocr_country_region(ocr_result)
    country_code.present? && !ReceiptAnalysisPipeline::Config::SUPPORTED_RECEIPT_COUNTRY_CODES.include?(country_code)
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

  def ai_not_receipt_decision(ocr_result, ai_result, receipt_signal)
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
end
