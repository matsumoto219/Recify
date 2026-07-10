class ReceiptOcrService
  CLIENT_ERROR_CODE_MAPPING = {
    "ocr_invalid_response" => "ocr_api_error",
    "ocr_failed" => "ocr_api_error"
  }.freeze

  class OcrError < StandardError
    attr_reader :error_code

    def initialize(error_code, message = nil)
      @error_code = error_code
      super(message || error_code.to_s)
    end
  end

  def self.call(image, provider: "azure_document_intelligence", runtime_config: nil, before_provider_call: nil, after_provider_success_response: nil)
    new(
      image: image,
      provider: provider,
      runtime_config: runtime_config,
      before_provider_call: before_provider_call,
      after_provider_success_response: after_provider_success_response
    ).call
  end

  def self.error_result(error_code:, provider: "azure_document_intelligence", model_id: nil, polling_metrics: nil, provider_error_detail: nil)
    Ocr::ResultTemplate.error_result(
      error_code: error_code,
      provider: provider,
      model_id: model_id,
      polling_metrics: polling_metrics,
      provider_error_detail: provider_error_detail
    )
  end

  def self.available?
    Ocr::AvailabilityChecker.call
  end

  def initialize(image:, provider: "azure_document_intelligence", runtime_config: nil, before_provider_call: nil, after_provider_success_response: nil)
    @image = image
    @provider = provider
    @runtime_config = runtime_config || ExternalServices.runtime_config_snapshot.ocr
    @before_provider_call = before_provider_call
    @after_provider_success_response = after_provider_success_response
  end

  def call
    Rails.logger.info("[OCR] start provider=#{provider}")

    validate_image!

    # 1) 外部OCR API呼び出し
    response = Ocr::Client.new(
      image: image,
      provider: provider,
      runtime_config: runtime_config,
      before_provider_call: before_provider_call,
      after_provider_success_response: after_provider_success_response
    ).call

    # 2) レスポンスを内部形式へ正規化
    parsed = Ocr::ResponseParser.new(response: response, provider: provider).call

    if parsed[:success]
      Rails.logger.info("[OCR] success lines=#{parsed[:lines].size}")
      ExternalServices.mark_success!(:ocr)
      parsed
    else
      Rails.logger.warn("[OCR] failed code=#{parsed[:error_code]}")
      mark_external_failure(parsed[:error_code], detail: parsed.dig(:meta, :provider_error_detail))
      parsed
    end
  rescue Ocr::OcrTimeoutError => e
    handle_ocr_error(e)
  rescue Ocr::OcrError, OcrError => e
    handle_ocr_error(e)
  rescue Usage::LimitExceeded
    raise
  rescue Timeout::Error
    Rails.logger.error("[OCR] timeout")
    ExternalServices.mark_failure!(:ocr, error_code: "ocr_timeout")
    build_error_result("ocr_timeout")
  rescue ActiveStorage::FileNotFoundError
    Rails.logger.error("[OCR] image_corrupted")
    ExternalServices.mark_failure!(:ocr, error_code: "image_corrupted")
    build_error_result("image_corrupted")
  rescue StandardError => e
    Rails.logger.error("[OCR] unexpected_error class=#{e.class} message=#{e.message}")
    ExternalServices.mark_failure!(:ocr, error_code: "unexpected_error")
    build_error_result("unexpected_error")
  end

  private

  attr_reader :image, :provider, :runtime_config, :before_provider_call, :after_provider_success_response

  def validate_image!
    unless image&.attached?
      raise OcrError.new("image_missing")
    end
  end

  def handle_ocr_error(error)
    error_code = normalized_ocr_error_code(error)
    provider_error_detail = provider_error_detail_for(error)

    Rails.logger.error("[OCR] ocr_error code=#{error_code} class=#{error.class}")
    mark_external_failure(error_code, detail: provider_error_detail)
    build_error_result(
      error_code,
      polling_metrics: polling_metrics_for(error),
      provider_error_detail: provider_error_detail
    )
  end

  def mark_external_failure(error_code, detail: nil)
    if detail.present?
      ExternalServices.mark_failure!(:ocr, error_code: error_code, detail: detail)
    else
      ExternalServices.mark_failure!(:ocr, error_code: error_code)
    end
  end

  def normalized_ocr_error_code(error)
    raw_code =
      if error.respond_to?(:error_code)
        error.error_code
      else
        error.message
      end

    code = raw_code.to_s.presence || "ocr_api_error"
    CLIENT_ERROR_CODE_MAPPING.fetch(code, code)
  end

  def build_error_result(error_code, polling_metrics: nil, provider_error_detail: nil)
    self.class.error_result(
      error_code: error_code,
      provider: provider,
      model_id: nil,
      polling_metrics: polling_metrics,
      provider_error_detail: provider_error_detail
    )
  end

  def polling_metrics_for(error)
    return unless error.respond_to?(:polling_metrics)

    error.polling_metrics.presence
  end

  def provider_error_detail_for(error)
    return unless error.respond_to?(:provider_error_detail)

    error.provider_error_detail.presence
  end
end
