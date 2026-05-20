class ReceiptOcrService
  CLIENT_ERROR_CODE_MAPPING = {
    "ocr_invalid_response" => "ocr_api_error",
    "ocr_failed" => "ocr_api_error"
  }.freeze

  class OcrError < StandardError
    attr_reader :error_code

    def initialize(error_code, message = nil)
      @error_code = error_code
      super(message)
    end
  end

  def self.call(image, provider: "azure_document_intelligence")
    new(image: image, provider: provider).call
  end

  def initialize(image:, provider: "azure_document_intelligence")
    @image = image
    @provider = provider
  end

  def call
    Rails.logger.info("[OCR] start provider=#{provider}")

    validate_image!

    # 1) 外部OCR API呼び出し（まだ未実装ならダミーでもOK）
    response = Ocr::Client.new(image: image, provider: provider).call

    # 2) レスポンスを内部形式へ正規化
    parsed = Ocr::ResponseParser.new(response: response, provider: provider).call

    if parsed[:success]
      Rails.logger.info("[OCR] success lines=#{parsed[:lines].size}")
      ExternalServiceStatus.mark_success!(:ocr)
      parsed
    else
      Rails.logger.warn("[OCR] failed code=#{parsed[:error_code]}")
      ExternalServiceStatus.mark_failure!(:ocr, error_code: parsed[:error_code])
      parsed
    end
  rescue Ocr::OcrTimeoutError => e
    handle_ocr_error(e)
  rescue Ocr::OcrError, OcrError => e
    handle_ocr_error(e)
  rescue Timeout::Error
    Rails.logger.error("[OCR] timeout")
    ExternalServiceStatus.mark_failure!(:ocr, error_code: "ocr_timeout")
    build_error_result("ocr_timeout")
  rescue ActiveStorage::FileNotFoundError
    Rails.logger.error("[OCR] image_corrupted")
    ExternalServiceStatus.mark_failure!(:ocr, error_code: "image_corrupted")
    build_error_result("image_corrupted")
  rescue StandardError => e
    Rails.logger.error("[OCR] unexpected_error class=#{e.class} message=#{e.message}")
    ExternalServiceStatus.mark_failure!(:ocr, error_code: "unexpected_error")
    build_error_result("unexpected_error")
  end

  private

  attr_reader :image, :provider

  def validate_image!
    unless image&.attached?
      raise OcrError.new("image_missing", "画像が添付されていません")
    end
  end

  def handle_ocr_error(error)
    error_code = normalized_ocr_error_code(error)

    Rails.logger.error("[OCR] ocr_error code=#{error_code} class=#{error.class}")
    ExternalServiceStatus.mark_failure!(:ocr, error_code: error_code)
    build_error_result(error_code)
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

  def build_error_result(error_code)
    Ocr::ResultTemplate.error_result(
      error_code: error_code,
      provider: provider,
      model_id: nil
    )
  end
end
