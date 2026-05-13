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
      line_total = to_i(fetch_value(item, :line_total))
      return line_total if line_total.positive?

      price = to_i(fetch_value(item, :price))
      quantity = to_i(fetch_value(item, :quantity, 1))
      quantity = 1 if quantity <= 0

      price * quantity
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
      return 0 if blank?(value)

      value.to_i
    end

    def fetch_value(object, key, default = nil)
      if object.respond_to?(:[])
        object[key] || object[key.to_s] || default
      elsif object.respond_to?(key)
        object.public_send(key)
      else
        default
      end
    end

    def blank?(value)
      value.nil? || value == ""
    end
  end
end
