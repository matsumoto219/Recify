module Analysis
  class ReceiptProcessingErrorMapper
    # 役割:
    # - OCR / AI / 外部サービスのエラーコードを統一フォーマットへ変換
    # - error_code（内部ログ用）と error_category（ユーザー表示用）を分離
    #
    # 使用箇所:
    # - Receipts::Processing::Pipeline::FinalizeStep 内で利用
    #
    # 設計方針:
    # - OCR / AI / System を分類
    # - 未定義コードは system_error にフォールバック

    # 内部エラーコード → ユーザー向けカテゴリ
    ERROR_CATEGORY_MAPPING = {
      # OCR系
      "no_text_detected" => "image_error",
      "receipt_not_detected" => "image_error",
      "ocr_unreadable" => "image_error",
      "ocr_timeout" => "ocr_error",
      "ocr_api_error" => "ocr_error",

      # 画像系
      "image_missing" => "image_error",
      "image_invalid_format" => "image_error",
      "image_corrupted" => "image_error",
      "unsupported_country" => "image_error",

      # AI系
      "ai_timeout" => "ai_error",
      "ai_unavailable" => "ai_error",
      "ai_quota_exceeded" => "ai_error",
      "ai_rate_limited" => "ai_error",
      "ai_auth_error" => "ai_error",
      "ai_invalid_request" => "ai_error",
      "ai_not_receipt" => "image_error",
      "ai_not_receipt_uncertain" => "image_error",
      "ai_invalid_response" => "ai_error",
      "ai_config_error" => "ai_error",
      "analysis_missing_keys" => "ai_error",
      "ai_primary_failed" => "ai_error",
      "ai_fallback_failed" => "ai_error",

      "ai_api_error" => "ai_error",
      "analysis_items_invalid" => "ai_error",
      "analysis_value_invalid" => "ai_error",

      # 外部サービス系
      "external_service_unavailable" => "ocr_error",
      "external_service_auth_error" => "ocr_error",
      "external_service_quota_exceeded" => "ocr_error",
      "external_service_rate_limited" => "ocr_error",

      # その他
      "unexpected_error" => "system_error"
    }.freeze

    # クラスメソッドで統一インターフェース提供
    def self.map(error_code)
      new(error_code).map
    end

    def initialize(error_code)
      @error_code = normalize(error_code)
    end

    # メイン処理
    def map
      {
        error_code: @error_code,
        error_category: category_for(@error_code)
      }
    end

    private

    # nilやシンボルを吸収
    def normalize(error_code)
      return "unexpected_error" if error_code.nil?

      error_code.to_s
    end

    def category_for(code)
      ERROR_CATEGORY_MAPPING[code] || "system_error"
    end
  end
end
