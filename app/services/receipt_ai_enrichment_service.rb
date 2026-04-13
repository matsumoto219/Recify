class ReceiptAiEnrichmentService
  class AiEnrichmentError < StandardError
    attr_reader :error_code

    def initialize(error_code, message)
      @error_code = error_code
      super(message)
    end
  end

  class << self
    def call(ocr_result)
      new(ocr_result).call
    end
  end

  def initialize(ocr_result, client: Ai::Client.new)
    @ocr_result = ocr_result || {}
    @client = client
  end

  def call
    Rails.logger.info("[AIEnrichment] start")

    validate_ocr_result!

    input = Ai::PromptBuilder.build(ocr_result)
    result = client.call(input)

    if result[:success]
      ExternalServiceStatus.mark_success!(:ai)
    else
      ExternalServiceStatus.mark_failure!(:ai, error_code: result[:error_code])
    end

    log_result(result)
    result
  rescue AiEnrichmentError => e
    Rails.logger.error("[AIEnrichment] #{e.error_code} #{e.message}")
    ExternalServiceStatus.mark_failure!(:ai, error_code: e.error_code)
    Ai::ResultTemplate.error(
      error_code: e.error_code,
      review_reasons: [ e.error_code ],
      meta: { message: e.message }
    )
  rescue StandardError => e
    Rails.logger.error("[AIEnrichment] unexpected_error #{e.class}: #{e.message}")
    ExternalServiceStatus.mark_failure!(:ai, error_code: "ai_api_error")
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

  attr_reader :ocr_result, :client

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
