class ReceiptAiEnrichmentService
  class AiEnrichmentError < StandardError
    attr_reader :error_code

    def initialize(error_code, message)
      @error_code = error_code
      super(message)
    end
  end

  class << self
    def call(ocr_result, ai_name_completion_enabled: false, capture_input: nil)
      new(
        ocr_result,
        ai_name_completion_enabled: ai_name_completion_enabled,
        capture_input: capture_input
      ).call
    end

    def available?
      Ai::AvailabilityChecker.call
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

  def initialize(ocr_result, ai_name_completion_enabled: false, capture_input: nil, client: Ai::Client.new)
    @ocr_result = ocr_result || {}
    @ai_name_completion_enabled = ai_name_completion_enabled == true
    @capture_input = capture_input
    @client = client
  end

  def call
    Rails.logger.info("[AIEnrichment] start")

    validate_ocr_result!

    input = Ai::PromptBuilder.build(
      ocr_result,
      ai_name_completion_enabled: ai_name_completion_enabled
    )
    capture_input!(input)

    result = client.call(input)

    if ai_service_healthy_result?(result)
      ExternalServices.mark_success!(:ai)
    else
      ExternalServices.mark_failure!(:ai, error_code: result[:error_code])
    end

    log_result(result)
    result
  rescue InputCaptureError
    raise
  rescue AiEnrichmentError => e
    Rails.logger.error("[AIEnrichment] #{e.error_code} #{e.message}")
    ExternalServices.mark_failure!(:ai, error_code: e.error_code)
    Ai::ResultTemplate.error(
      error_code: e.error_code,
      review_reasons: [ e.error_code ],
      meta: { message: e.message }
    )
  rescue StandardError => e
    Rails.logger.error("[AIEnrichment] unexpected_error #{e.class}: #{e.message}")
    ExternalServices.mark_failure!(:ai, error_code: "ai_api_error")
    Ai::ResultTemplate.error(
      error_code: "ai_api_error",
      review_reasons: [ "unexpected_error" ],
      meta: {
        error_class: e.class.name,
        error_message: e.message
      }
    )
  end

  private

  attr_reader :ocr_result, :ai_name_completion_enabled, :capture_input, :client

  def capture_input!(input)
    return unless capture_input

    capture_input.call(input)
  rescue StandardError => e
    raise InputCaptureError.new(e)
  end

  def ai_service_healthy_result?(result)
    result[:success] || result[:error_code].to_s == "ai_not_receipt"
  end

  def validate_ocr_result!
    raise AiEnrichmentError.new("analysis_missing_keys", "OCR結果が不正です") unless ocr_result.is_a?(Hash)
    raise AiEnrichmentError.new("analysis_missing_keys", "OCRが失敗しています") unless ocr_result[:success] == true || ocr_result["success"] == true

    lines = ocr_result[:lines] || ocr_result["lines"]
    raise AiEnrichmentError.new("analysis_missing_keys", "OCR結果のlinesが不足しています") unless lines.is_a?(Array)

    candidates = ocr_result[:candidates] || ocr_result["candidates"]
    raise AiEnrichmentError.new("analysis_missing_keys", "OCR結果のcandidatesが不足しています") unless candidates.is_a?(Hash)
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
