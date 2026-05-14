module Amounts
  module MismatchCodes
    # 内部コード一覧
    CODES = {
      total_mismatch: "TOTAL_MISMATCH",
      item_total_mismatch: "ITEM_TOTAL_MISMATCH",
      tax_amount_mismatch: "TAX_AMOUNT_MISMATCH",
      tax_detail_mismatch: "TAX_DETAIL_MISMATCH",
      tax_detail_rate_mismatch: "TAX_DETAIL_RATE_MISMATCH",
      tax_detail_incomplete: "TAX_DETAIL_INCOMPLETE",
      tax_detail_partial: "TAX_DETAIL_PARTIAL",
      ocr_total_mismatch: "OCR_TOTAL_MISMATCH",
      price_tax_inclusion_uncertain: "PRICE_TAX_INCLUSION_UNCERTAIN",
      insufficient_data: "INSUFFICIENT_DATA",
      zero_amount_item_incomplete: "ZERO_AMOUNT_ITEM_INCOMPLETE",
      discount_data_incomplete: "DISCOUNT_DATA_INCOMPLETE"
    }.freeze

    def self.code(symbol)
      CODES[symbol]
    end

    def self.valid?(symbol)
      CODES.key?(symbol)
    end

    def self.all
      CODES.keys
    end
  end
end
