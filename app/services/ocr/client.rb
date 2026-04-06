module Ocr
  class Client
    def initialize(image:, provider: nil)
      @image = image
      @provider = provider
    end

    def call
      Rails.logger.info("[OCR::Client] request start provider=#{provider}")

      # ダミー実装（Azure風レスポンス）
      response = {
        "raw_text" => <<~TEXT,
          サンプルストア
          東京都渋谷区1-2-3
          TEL 03-1234-5678
          2026/04/02 12:34
          コーヒー 180
          サンド 550 x2
          小計 1180
          消費税 80
          チップ 100
          合計 1280
          Master
        TEXT

        "lines" => [
          "サンプルストア",
          "東京都渋谷区1-2-3",
          "TEL 03-1234-5678",
          "2026/04/02 12:34",
          "コーヒー 180",
          "サンド 550 x2",
          "小計 1180",
          "消費税 80",
          "チップ 100",
          "合計 1280",
          "Master"
        ],

        # Azure Document Intelligence 風
        "fields" => {
          "MerchantName" => { "valueString" => "サンプルストア" },
          "MerchantAddress" => { "valueString" => "東京都渋谷区1-2-3" },
          "MerchantPhoneNumber" => { "valueString" => "03-1234-5678" },
          "TransactionDate" => { "valueString" => "2026-04-02" },
          "TransactionTime" => { "valueString" => "12:34" },
          "Total" => { "valueNumber" => 1280 },
          "Subtotal" => { "valueNumber" => 1180 },
          "TotalTax" => { "valueNumber" => 80 },
          "Tip" => { "valueNumber" => 100 },
          "CountryRegion" => { "valueString" => "JP" },
          "ReceiptType" => { "valueString" => "Meal" },

          "Payments" => {
            "valueArray" => [
              {
                "valueObject" => {
                  "Method" => { "valueString" => "CreditCard" },
                  "Amount" => { "valueNumber" => 1280 }
                }
              }
            ]
          },

          "TaxDetails" => {
            "valueArray" => [
              {
                "valueObject" => {
                  "Description" => { "valueString" => "Sales Tax" },
                  "Amount" => { "valueNumber" => 80 },
                  "Rate" => { "valueNumber" => 10 },
                  "NetAmount" => { "valueNumber" => 800 }
                }
              }
            ]
          },

          "Items" => {
            "valueArray" => [
              {
                "valueObject" => {
                  "Description" => { "valueString" => "コーヒー" },
                  "Quantity" => { "valueNumber" => 1 },
                  "QuantityUnit" => { "valueString" => "杯" },
                  "Price" => { "valueNumber" => 180 },
                  "TotalPrice" => { "valueNumber" => 180 },
                  "ProductCode" => { "valueString" => "C001" }
                },
                "confidence" => 0.98
              },
              {
                "valueObject" => {
                  "Description" => { "valueString" => "サンド" },
                  "Quantity" => { "valueNumber" => 2 },
                  "QuantityUnit" => { "valueString" => "個" },
                  "Price" => { "valueNumber" => 550 },
                  "TotalPrice" => { "valueNumber" => 1100 },
                  "ProductCode" => { "valueString" => "S001" }
                },
                "confidence" => 0.97
              }
            ]
          }
        }
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
