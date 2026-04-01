class ReceiptOcrService
  class OcrError < StandardError
    attr_reader :error_code

    def initialize(error_code, message)
      @error_code = error_code
      super(message)
    end
  end

  def self.call(image)
    raise OcrError.new("image_missing", "画像が添付されていません") unless image&.attached?

    {
      raw_lines: [
        "ｻﾝﾌﾟﾙｽﾄｱ",
        "2026/04/02 12:34",
        "ｺｰﾋｰ 180",
        "ｻﾝﾄﾞ 550 x2",
        "合計 1280",
        "Master"
      ]
    }
  rescue ActiveStorage::FileNotFoundError
    raise OcrError.new("image_corrupted", "画像ファイルを読み込めませんでした")
  end
end
