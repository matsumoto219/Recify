# frozen_string_literal: true

module GeneratedReceipts
  class MeasurementContract
    Projection = Data.define(
      :exact_reference_amount,
      :projected_reference_line_total,
      :discount_amount,
      :discounted_source_line_total,
      :projected_gross_line_total
    )

    DECIMAL_PATTERN = /\A(?:0|[1-9]\d*)(?:\.\d+)?\z/.freeze
    UNIT_SCALES = {
      "gram" => [ "mass", Rational(1) ],
      "kilogram" => [ "mass", Rational(1_000) ],
      "milligram" => [ "mass", Rational(1, 1_000) ],
      "liter" => [ "volume", Rational(1_000) ],
      "milliliter" => [ "volume", Rational(1) ],
      "cubic_centimeter" => [ "volume", Rational(1) ]
    }.freeze

    class << self
      def project(source_item:, tax_rate:, tax_rounding:, discount_rounding:)
        source = source_item.to_h
        price = exact_decimal(source["reference_price_amount"], max_scale: 6, allow_zero: true)
        reference_quantity = exact_decimal(source["reference_quantity"], max_scale: 3)
        purchased_quantity = exact_decimal(source["purchased_quantity"], max_scale: 3)
        conversion_ratio = exact_conversion_ratio(
          from: source["purchased_unit"],
          to: source["reference_unit"]
        )
        return nil unless price && reference_quantity && purchased_quantity && conversion_ratio

        exact_amount = price * purchased_quantity * conversion_ratio / reference_quantity
        projected_amount = round_value(exact_amount, "round")
        discount = projected_discount(
          source,
          projected_amount,
          rounding: discount_rounding
        )
        return nil if discount.nil? || discount.negative? || discount > projected_amount

        discounted_amount = projected_amount - discount
        gross_amount = projected_gross_amount(
          source["reference_price_tax_inclusion"],
          discounted_amount,
          tax_rate: tax_rate,
          rounding: tax_rounding
        )

        Projection.new(
          exact_reference_amount: exact_amount,
          projected_reference_line_total: projected_amount,
          discount_amount: discount,
          discounted_source_line_total: discounted_amount,
          projected_gross_line_total: gross_amount
        )
      rescue ArgumentError, TypeError, ZeroDivisionError
        nil
      end

      def rounding_matches(exact_amount:, printed_line_total:)
        return [] if exact_amount.nil? || printed_line_total.nil?

        printed = Integer(printed_line_total.to_s, 10)
        {
          "floor" => exact_amount.floor,
          "half_up" => (exact_amount + Rational(1, 2)).floor,
          "ceil" => exact_amount.ceil
        }.filter_map { |mode, amount| mode if amount == printed }
      rescue ArgumentError, TypeError
        []
      end

      private

      def exact_decimal(value, max_scale:, allow_zero: false)
        text = value.to_s
        return nil unless text.match?(DECIMAL_PATTERN)
        return nil if text.include?(".") && text.split(".", 2).last.length > max_scale

        value = Rational(text)
        return nil if value.negative?
        return nil if value.zero? && !allow_zero

        value
      end

      def exact_conversion_ratio(from:, to:)
        from_dimension, from_scale = UNIT_SCALES[from.to_s]
        to_dimension, to_scale = UNIT_SCALES[to.to_s]
        return nil unless from_dimension && from_dimension == to_dimension

        from_scale / to_scale
      end

      def projected_discount(source, projected_amount, rounding:)
        if source.key?("discount_rate") && !source["discount_rate"].nil?
          rate = exact_decimal(source["discount_rate"], max_scale: 6, allow_zero: true)
          return nil unless rate && rate <= 1

          round_value(projected_amount * rate, rounding)
        elsif source.key?("discount_amount") && !source["discount_amount"].nil?
          amount = exact_decimal(source["discount_amount"], max_scale: 0, allow_zero: true)
          amount&.denominator == 1 ? amount.to_i : nil
        else
          0
        end
      end

      def projected_gross_amount(tax_inclusion, discounted_amount, tax_rate:, rounding:)
        case tax_inclusion
        when "gross"
          discounted_amount
        when "net"
          rate = exact_decimal(tax_rate, max_scale: 6, allow_zero: true)
          return nil unless rate

          discounted_amount + round_value(discounted_amount * rate, rounding)
        end
      end

      def round_value(value, mode)
        case mode
        when "ceil"
          value.ceil
        when "round"
          (value + Rational(1, 2)).floor
        else
          value.floor
        end
      end
    end
  end
end
