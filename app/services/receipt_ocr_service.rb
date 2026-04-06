class ReceiptOcrService
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
      parsed
    else
      Rails.logger.warn("[OCR] failed code=#{parsed[:error_code]}")
      parsed
    end
  rescue OcrError => e
    Rails.logger.error("[OCR] ocr_error code=#{e.error_code}")
    build_error_result(e.error_code)
  rescue Timeout::Error
    Rails.logger.error("[OCR] timeout")
    build_error_result("ocr_timeout")
  rescue ActiveStorage::FileNotFoundError
    Rails.logger.error("[OCR] image_corrupted")
    build_error_result("image_corrupted")
  rescue StandardError => e
    Rails.logger.error("[OCR] unexpected_error class=#{e.class} message=#{e.message}")
    build_error_result("unexpected_error")
  end

  private

  attr_reader :image, :provider

  def validate_image!
    unless image&.attached?
      raise OcrError.new("image_missing", "画像が添付されていません")
    end
  end

  def build_error_result(error_code)
    {
      success: false,
      raw_text: "",
      lines: [],
      candidates: {
        store_name: nil,
        store_address: nil,
        store_phone_number: nil,
        purchased_at_text: nil,
        total_amount: nil,
        subtotal_amount: nil,
        tax_amount: nil,
        tax_rate: nil,
        tip_amount: nil,
        country_region: nil,
        receipt_type: nil,
        payments: [],
        tax_details: [],
        payment_method_text: nil,
        items: [],
        confidence_summary: {
          merchant_name: nil,
          purchased_at: nil,
          total_amount: nil,
          subtotal_amount: nil,
          tax_amount: nil,
          tax_rate: nil,
          items_average: nil,
          overall: nil
        }
      },
      error_code: error_code,
      meta: {
        provider: provider,
        model_id: nil,
        raw_response_included: false
      }
    }
  end
end
