module Ocr
  class Client
    def initialize(image:, provider: nil)
      @image = image
      @provider = provider
    end

    def call
      Rails.logger.info("[OCR::Client] request start provider=#{provider}")

      # ダミー実装
      response = {
        "raw_text" => <<~TEXT
          サンプルストア
          2026/04/02 12:34
          コーヒー 180
          サンド 550 x2
          合計 1280
          Master
        TEXT
      }

      Rails.logger.info("[OCR::Client] request success provider=#{provider}")
      response
    rescue StandardError => e
      Rails.logger.error("[OCR::Client] request failed class=#{e.class} message=#{e.message}")
      raise
    end

    private

    attr_reader :image, :provider
  end
end
