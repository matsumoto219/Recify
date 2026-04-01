class ReceiptOcrService
  class OcrError < StandardError
    attr_reader :error_code

    def initialize(error_code, message)
      @error_code = error_code
      super(message)
    end
  end

  def self.call(image)
    Rails.logger.info("[OCR] start")

    unless image&.attached?
      Rails.logger.error("[OCR] image_missing")
      raise OcrError.new("image_missing", "画像が添付されていません")
    end

    result = {
      raw_lines: [
        "ｻﾝﾌﾟﾙｽﾄｱ",
        "2026/04/02 12:34",
        "ｺｰﾋｰ 180",
        "ｻﾝﾄﾞ 550 x2",
        "合計 1280",
        "Master"
      ]
    }

    Rails.logger.info("[OCR] success raw_lines_count=#{result[:raw_lines].size}")

    result
  rescue ActiveStorage::FileNotFoundError
    Rails.logger.error("[OCR] image_corrupted")
    raise OcrError.new("image_corrupted", "画像ファイルを読み込めませんでした")
  end
end
