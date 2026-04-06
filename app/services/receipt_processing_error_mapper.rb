# ReceiptProcessingErrorMapper
#
# 役割:
# - OCR / AI / 外部サービスのエラーコードを統一フォーマットへ変換
# - error_code（内部ログ用）と error_category（ユーザー表示用）を分離
#
# 使用箇所:
# - ReceiptAnalysisService 内で利用
#
# 設計方針:
# - OCR / AI / System を分類
# - 未定義コードは system_error にフォールバック

class ReceiptProcessingErrorMapper
  # 内部エラーコード → ユーザー向けカテゴリ
  ERROR_CATEGORY_MAPPING = {
    # OCR系
    "ocr_unreadable" => "image_error",
    "ocr_timeout" => "ocr_error",
    "ocr_api_error" => "ocr_error",

    # AI系
    "ai_timeout" => "ai_error",
    "ai_invalid_response" => "ai_error",
    "analysis_missing_keys" => "ai_error",

    # 外部サービス系
    "external_service_unavailable" => "system_error",
    "external_service_auth_error" => "system_error",

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
