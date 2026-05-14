# frozen_string_literal: true

module Amounts
  class TaxDetailAggregator
    def initialize(items:, fallback_tax_rate: nil, fallback_net_amount: nil, fallback_tax_amount: nil, rounding_mode: :floor)
      @items = Array(items)
      @fallback_tax_rate = normalize_tax_rate(fallback_tax_rate)
      @fallback_net_amount = to_i(fallback_net_amount)
      @fallback_tax_amount = to_i(fallback_tax_amount)
      @rounding_mode = Amounts::Rounding.normalize_rounding_mode(rounding_mode)
    end

    def call
      groups = grouped_tax_details
      groups = fallback_tax_details if groups.blank?

      groups.map do |rate, amounts|
        {
          description: description_for(rate),
          rate: rate,
          net_amount: amounts[:net_amount],
          amount: amounts[:amount]
        }
      end
    end

    private

    # receipt_items は税込単価前提。
    # item.tax_rate が無い場合のみ fallback_tax_rate を使う。
    # 税率ごとに税込金額を集計してから税抜金額・税額を逆算する。
    # 明細ごとに端数処理すると内税額がズレるため、税率単位で一括計算する。
    def grouped_tax_details
      gross_totals = @items.each_with_object({}) do |item, grouped|
        tax_rate = normalize_tax_rate(fetch_value(item, :tax_rate))
        tax_rate = @fallback_tax_rate if tax_rate <= 0
        next if tax_rate <= 0

        line_total = item_line_total(item)
        next if line_total <= 0

        grouped[tax_rate] ||= 0
        grouped[tax_rate] += line_total
      end

      gross_totals.each_with_object({}) do |(tax_rate, gross_total), grouped|
        tax_amount = rounded_tax_from_gross(gross_total, tax_rate)
        net_amount = gross_total - tax_amount

        grouped[tax_rate] = {
          net_amount: net_amount,
          amount: tax_amount
        }
      end
    end

    def fallback_tax_details
      return {} if @fallback_tax_rate <= 0
      return {} if @fallback_net_amount <= 0
      return {} if @fallback_tax_amount < 0

      {
        @fallback_tax_rate => {
          net_amount: @fallback_net_amount,
          amount: @fallback_tax_amount
        }
      }
    end

    def item_line_total(item)
      line_total = fetch_value(item, :line_total)
      return to_i(line_total) if present?(line_total)
      return 0 unless countable_quantity_unit?(fetch_value(item, :quantity_unit))

      price = to_amount_decimal(fetch_value(item, :price))
      quantity = to_decimal(fetch_value(item, :quantity, 1))
      quantity = BigDecimal("1") if quantity <= 0

      round_amount(price * quantity)
    end

    def description_for(rate)
      percentage = rate * 100
      formatted_percentage = percentage.frac.zero? ? percentage.to_i.to_s : percentage.to_s("F")

      "#{formatted_percentage}%対象"
    end

    def normalize_tax_rate(value)
      return BigDecimal("0") if blank?(value)

      tax_rate = BigDecimal(value.to_s)
      tax_rate > 1 ? tax_rate / 100 : tax_rate
    rescue ArgumentError
      BigDecimal("0")
    end

    def rounded_tax_from_gross(gross_total, tax_rate)
      Amounts::Rounding.apply_rounding(BigDecimal(gross_total.to_s) * tax_rate / (BigDecimal("1") + tax_rate), @rounding_mode)
    end

    def to_i(value)
      Amounts::NumberParser.parse_amount(value)
    end

    def fetch_value(object, key, default = nil)
      if object.respond_to?(:key?)
        return object[key] if object.key?(key)
        return object[key.to_s] if object.key?(key.to_s)
      elsif object.respond_to?(:[])
        value = object[key]
        return value unless value.nil?

        string_value = object[key.to_s]
        return string_value unless string_value.nil?
      elsif object.respond_to?(key)
        return object.public_send(key)
      end

      default
    end

    def blank?(value)
      value.nil? || value == ""
    end

    def present?(value)
      !blank?(value)
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
  end
end
