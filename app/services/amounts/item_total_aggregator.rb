module Amounts
  class ItemTotalAggregator
    def initialize(items:)
      @items = Array(items)
    end

    def call
      normalized = normalized_items

      {
        items: normalized,
        total: normalized.sum { |item| item[:line_total].to_i }
      }
    end

    private

    def normalized_items
      @items.map do |item|
        original_line_total = item_line_total(item)
        discount_amount = to_i(fetch_value(item, :discount_amount))

        adjusted_line_total = [ original_line_total - discount_amount, 0 ].max

        item.merge(
          original_line_total: original_line_total,
          discount_amount: discount_amount,
          line_total: adjusted_line_total
        )
      end
    end

    def item_line_total(item)
      line_total = to_i(fetch_value(item, :line_total))
      return line_total if line_total.positive?

      price = to_i(fetch_value(item, :price))
      quantity = to_i(fetch_value(item, :quantity))
      quantity = 1 if quantity <= 0

      price * quantity
    end

    def fetch_value(item, key)
      item[key] || item[key.to_s]
    end

    def to_i(value)
      value.to_s.delete(",").to_i
    end
  end
end
