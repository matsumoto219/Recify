class ReceiptAiEnrichmentService
  class AiEnrichmentError < StandardError
    attr_reader :error_code, :internal_reason_code

    def initialize(error_code, internal_reason_code:)
      @error_code = error_code
      @internal_reason_code = internal_reason_code.to_s
      super(@internal_reason_code)
    end
  end

  class << self
    def call(ocr_result, ai_name_completion_enabled: false, runtime_config: nil, capture_input: nil, before_provider_call: nil)
      new(
        ocr_result,
        ai_name_completion_enabled: ai_name_completion_enabled,
        runtime_config: runtime_config,
        capture_input: capture_input,
        before_provider_call: before_provider_call
      ).call
    end

    def available?
      Ai::AvailabilityChecker.call
    end

    def error_result(...)
      Ai::ResultTemplate.error(...)
    end

    def provider_metrics(...)
      Ai::ProviderMetrics.build(...)
    end
  end

  class InputCaptureError < StandardError
    attr_reader :original_error

    def initialize(original_error)
      @original_error = original_error
      super(original_error.message)
      set_backtrace(original_error.backtrace)
    end
  end

  def initialize(ocr_result, ai_name_completion_enabled: false, runtime_config: nil, capture_input: nil, before_provider_call: nil, client: nil)
    @ocr_result = ocr_result
    @ai_name_completion_enabled = ai_name_completion_enabled == true
    @capture_input = capture_input
    @before_provider_call = before_provider_call
    @client = client || Ai::Client.new(runtime_config: runtime_config || ExternalServices.runtime_config_snapshot.ai)
  end

  def call
    Rails.logger.info("[AIEnrichment] start")

    validate_ocr_result!

    input = Ai::PromptBuilder.build(
      ocr_result,
      ai_name_completion_enabled: ai_name_completion_enabled
    )
    capture_input!(input)

    result = call_ai_client(input)
    annotate_ai_name_completion!(result)

    if ai_service_healthy_result?(result)
      ExternalServices.mark_success!(:ai)
    else
      mark_external_failure(result[:error_code], detail: ai_provider_error_detail_for(result))
    end

    log_result(result)
    result
  rescue InputCaptureError
    raise
  rescue Usage::LimitExceeded
    raise
  rescue AiEnrichmentError => e
    Rails.logger.error("[AIEnrichment] #{e.error_code} reason=#{e.internal_reason_code}")
    ExternalServices.mark_failure!(:ai, error_code: e.error_code)
    Ai::ResultTemplate.error(
      error_code: e.error_code,
      review_reasons: [ e.error_code ],
      meta: { internal_reason_code: e.internal_reason_code }
    )
  rescue Ai::Errors::ProviderError => e
    error_code = e.error_code.presence || "ai_api_error"
    detail = provider_error_detail_from_exception(e)
    Rails.logger.error("[AIEnrichment] provider_error code=#{error_code} provider=#{e.provider}")
    mark_external_failure(error_code, detail: detail)
    Ai::ResultTemplate.error(
      error_code: error_code,
      review_reasons: [ error_code ],
      meta: { final_error_detail: detail }.compact
    )
  rescue StandardError => e
    Rails.logger.error("[AIEnrichment] unexpected_error #{e.class}: #{e.message}")
    ExternalServices.mark_failure!(:ai, error_code: "ai_api_error")
    Ai::ResultTemplate.error(
      error_code: "ai_api_error",
      review_reasons: [ "unexpected_error" ],
      meta: {
        error_class: e.class.name,
        internal_reason_code: "unexpected_error"
      }
    )
  end

  private

  attr_reader :ocr_result, :ai_name_completion_enabled, :capture_input, :before_provider_call, :client

  def capture_input!(input)
    return unless capture_input

    capture_input.call(input)
  rescue StandardError => e
    raise InputCaptureError.new(e)
  end

  def ai_service_healthy_result?(result)
    result[:success] || result[:error_code].to_s == "ai_not_receipt"
  end

  def annotate_ai_name_completion!(result)
    return result unless result.is_a?(Hash)

    meta = result[:meta].respond_to?(:to_h) ? result[:meta].to_h : {}
    result[:meta] = meta.merge(ai_name_completion_enabled: ai_name_completion_enabled)
    result
  end

  def ai_provider_error_detail_for(result)
    meta = result[:meta] if result.is_a?(Hash)
    return unless meta.respond_to?(:to_h)

    meta.to_h.with_indifferent_access[:final_error_detail].presence
  end

  def provider_error_detail_from_exception(error)
    metrics = error.respond_to?(:metrics) ? error.metrics || {} : {}

    ExternalServices.error_detail(
      service: :ai,
      provider: error.respond_to?(:provider) ? error.provider : metrics[:provider],
      phase: (error.respond_to?(:phase) ? error.phase : nil) || metrics[:phase],
      http_status: error.respond_to?(:provider_status) ? error.provider_status : metrics[:provider_status],
      provider_error_code: error.respond_to?(:provider_error_code) ? error.provider_error_code : metrics[:provider_error_code],
      provider_error_type: error.respond_to?(:provider_error_type) ? error.provider_error_type : metrics[:provider_error_type],
      provider_message: error.respond_to?(:provider_message) ? error.provider_message : metrics[:provider_message],
      request_id: error.respond_to?(:request_id) ? error.request_id : metrics[:request_id],
      retry_after: error.respond_to?(:retry_after) ? error.retry_after : metrics[:retry_after],
      model: metrics[:model],
      rate_limited: error.respond_to?(:rate_limited) ? error.rate_limited : metrics[:rate_limited],
      quota_exceeded: error.respond_to?(:quota_exceeded) ? error.quota_exceeded : metrics[:quota_exceeded],
      auth_error: error.respond_to?(:auth_error) ? error.auth_error : metrics[:auth_error]
    ).presence
  end

  def mark_external_failure(error_code, detail: nil)
    if detail.present?
      ExternalServices.mark_failure!(:ai, error_code: error_code, detail: detail)
    else
      ExternalServices.mark_failure!(:ai, error_code: error_code)
    end
  end

  def call_ai_client(input)
    return client.call(input, before_provider_call: before_provider_call) if before_provider_call

    client.call(input)
  end

  def validate_ocr_result!
    raise_input_error!("invalid_ocr_result") unless ocr_result.is_a?(Hash)
    raise_input_error!("ocr_failed") unless ocr_result[:success] == true || ocr_result["success"] == true

    lines = ocr_result[:lines] || ocr_result["lines"]
    raise_input_error!("missing_ocr_lines") unless lines.is_a?(Array)

    candidates = ocr_result[:candidates] || ocr_result["candidates"]
    raise_input_error!("missing_ocr_candidates") unless candidates.is_a?(Hash)
  end

  def raise_input_error!(internal_reason_code)
    raise AiEnrichmentError.new(
      "analysis_missing_keys",
      internal_reason_code: internal_reason_code
    )
  end

  def log_result(result)
    if result[:success]
      Rails.logger.info(
        "[AIEnrichment] success needs_review=#{result[:needs_review]} items_count=#{Array(result[:receipt_items_attributes]).size}"
      )
    else
      Rails.logger.warn(
        "[AIEnrichment] failed error_code=#{result[:error_code]} needs_review=#{result[:needs_review]}"
      )
    end
  end
end
