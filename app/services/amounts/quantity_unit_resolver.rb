# frozen_string_literal: true

module Amounts
  module QuantityUnitResolver
    private

    def normalized_quantity_unit_code_for(item)
      ReceiptQuantityUnit.normalize(
        fetch_value(item, :quantity_unit_code).presence || fetch_value(item, :quantity_unit)
      )
    end

    def countable_quantity_unit_for_item?(item)
      ReceiptQuantityUnit.countable?(normalized_quantity_unit_code_for(item))
    end

    def default_or_countable_quantity_unit_for_item?(item)
      quantity_unit_code = fetch_value(item, :quantity_unit_code)
      quantity_unit = fetch_value(item, :quantity_unit)
      return true if quantity_unit_code.blank? && quantity_unit.blank?

      ReceiptQuantityUnit.countable?(quantity_unit_code.presence || quantity_unit)
    end
  end
end
