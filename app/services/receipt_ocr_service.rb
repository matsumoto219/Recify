class ReceiptOcrService
  def self.call(image)
    raise StandardError, "画像が添付されていません" unless image.attached?

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
  end
end
