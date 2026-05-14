module Amounts
  class ItemTotalAggregator
    def initialize(items:)
      @items = Array(items)
    end

    def call
      normalized = normalized_items

      {
        items: normalized,
        total: normalized.sum { |item| to_i(item[:line_total]) }
      }
    end

    private

    def normalized_items
      @items.map do |item|
        original_line_total = original_line_total_for(item)
        discount_amount = to_i(fetch_value(item, :discount_amount))
        discount_rate = fetch_value(item, :discount_rate)

        adjusted_line_total = [ original_line_total - discount_amount, 0 ].max

        item_to_hash(item).merge(
          quantity: normalized_quantity_for(item),
          original_line_total: original_line_total,
          discount_amount: discount_amount,
          discount_rate: discount_rate,
          line_total: adjusted_line_total
        )
      end
    end

    def original_line_total_for(item)
      original_line_total = to_i(fetch_value(item, :original_line_total))
      return original_line_total if original_line_total.positive?

      item_line_total(item)
    end

    def item_to_hash(item)
      if item.respond_to?(:attributes)
        item.attributes.symbolize_keys
      elsif item.respond_to?(:to_h)
        item.to_h.symbolize_keys
      else
        {}
      end
    end

    def item_line_total(item)
      line_total_value = fetch_value(item, :line_total)
      return to_i(line_total_value) if value_present?(line_total_value)
      return 0 unless countable_quantity_unit?(fetch_value(item, :quantity_unit))

      price = to_amount_decimal(fetch_value(item, :price))
      round_amount(price * normalized_quantity_for(item))
    end

    def normalized_quantity_for(item)
      quantity = to_decimal(fetch_value(item, :quantity))
      quantity.positive? ? quantity : BigDecimal("1")
    end

    def fetch_value(item, key)
      return item[key] || item[key.to_s] if item.respond_to?(:[])
      return item.public_send(key) if item.respond_to?(key)

      nil
    end

    def to_i(value)
      Amounts::NumberParser.parse_amount(value)
    end

    def to_decimal(value)
      Amounts::NumberParser.parse_quantity(value)
    end

    def to_amount_decimal(value)
      BigDecimal(to_i(value).to_s)
    end

    def round_amount(value)
      BigDecimal(value.to_s).round(0).to_i
    end

    def countable_quantity_unit?(unit)
      ReceiptItem::COUNTABLE_QUANTITY_UNITS.include?(unit.to_s.strip)
    end

    def value_present?(value)
      !value.nil? && value != ""
    end
  end
end
