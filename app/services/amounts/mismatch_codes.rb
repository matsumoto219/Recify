module Amounts
  module MismatchCodes
    # 内部コード一覧
    CODES = {
      total_mismatch: "TOTAL_MISMATCH",
      item_total_mismatch: "ITEM_TOTAL_MISMATCH",
      tax_amount_mismatch: "TAX_AMOUNT_MISMATCH",
      tax_detail_mismatch: "TAX_DETAIL_MISMATCH",
      tax_detail_rate_mismatch: "TAX_DETAIL_RATE_MISMATCH",
      ocr_total_mismatch: "OCR_TOTAL_MISMATCH",
      price_tax_inclusion_uncertain: "PRICE_TAX_INCLUSION_UNCERTAIN",
      insufficient_data: "INSUFFICIENT_DATA",
      discount_data_incomplete: "DISCOUNT_DATA_INCOMPLETE"
    }.freeze

    # 表示用メッセージ（UI用）
    MESSAGES = {
      total_mismatch: "合計金額の整合性に問題があります",
      item_total_mismatch: "明細合計と合計金額が一致しません",
      tax_amount_mismatch: "税額の整合性に問題があります",
      tax_detail_mismatch: "税内訳の合計が一致しません",
      tax_detail_rate_mismatch: "税率ごとの内訳に問題があります",
      ocr_total_mismatch: "OCRの合計金額と計算結果が一致しません",
      price_tax_inclusion_uncertain: "税抜価格と税込価格が混在している可能性があります",
      insufficient_data: "計算に必要なデータが不足しています",
      discount_data_incomplete: "割引情報が不完全です"
    }.freeze

    def self.code(symbol)
      CODES[symbol]
    end

    def self.message(symbol)
      MESSAGES[symbol]
    end

    def self.valid?(symbol)
      CODES.key?(symbol)
    end

    def self.all
      CODES.keys
    end
  end
end
