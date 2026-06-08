module ReceiptAmountLimits
  DEFAULT_MAX = SystemSettings::AMOUNT_LIMIT_DEFAULT
  KEYS = {
    receipt_total_amount: "limits.receipt_total_amount_max",
    receipt_item_price: "limits.receipt_item_price_max",
    receipt_item_line_total: "limits.receipt_item_line_total_max",
    receipt_tax_amount: "limits.receipt_tax_amount_max",
    receipt_adjustment_amount: "limits.receipt_adjustment_amount_max",
    receipt_payment_amount: "limits.receipt_payment_amount_max"
  }.freeze

  class << self
    def receipt_total_amount_max
      limit_for(:receipt_total_amount)
    end

    def receipt_item_price_max
      limit_for(:receipt_item_price)
    end

    def receipt_item_line_total_max
      limit_for(:receipt_item_line_total)
    end

    def receipt_tax_amount_max
      limit_for(:receipt_tax_amount)
    end

    def receipt_adjustment_amount_max
      limit_for(:receipt_adjustment_amount)
    end

    def receipt_payment_amount_max
      limit_for(:receipt_payment_amount)
    end

    def limit_for(name)
      SystemSettings.limit_for(KEYS.fetch(name))
    rescue KeyError, SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
      DEFAULT_MAX
    end
  end
end
