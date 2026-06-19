# frozen_string_literal: true

module Amounts
  module QuantityUnitResolver
    private

    def normalized_quantity_unit_code_for(item)
      ReceiptQuantityUnit.normalize(fetch_value(item, :quantity_unit_code))
    end

    def countable_quantity_unit_for_item?(item)
      ReceiptQuantityUnit.countable?(normalized_quantity_unit_code_for(item))
    end

    def default_or_countable_quantity_unit_for_item?(item)
      quantity_unit_code = fetch_value(item, :quantity_unit_code)
      return true if quantity_unit_code.blank?

      ReceiptQuantityUnit.countable?(quantity_unit_code)
    end
  end
end
