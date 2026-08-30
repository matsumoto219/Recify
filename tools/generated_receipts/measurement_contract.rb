# frozen_string_literal: true

require "bigdecimal"

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
    EXACT_TOKEN_MAX_BYTES = 64
    MAX_INTEGER_BITS = 64
    MAX_EXACT_BITS = 128
    MAX_PRICE_AMOUNT = Rational(999_999_999_999)
    MAX_QUANTITY = Rational(9_999_999, 1_000)
    MAX_LINE_TOTAL = 999_999_999
    MAX_RATE = Rational(1)
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
        return nil unless source_item.is_a?(Hash)

        source = source_item
        price = exact_decimal(
          source["reference_price_amount"],
          max_scale: 6,
          maximum: MAX_PRICE_AMOUNT,
          allow_zero: true
        )
        reference_quantity = exact_decimal(
          source["reference_quantity"],
          max_scale: 3,
          maximum: MAX_QUANTITY
        )
        purchased_quantity = exact_decimal(
          source["purchased_quantity"],
          max_scale: 3,
          maximum: MAX_QUANTITY
        )
        conversion_ratio = exact_conversion_ratio(
          from: source["purchased_unit"],
          to: source["reference_unit"]
        )
        return nil unless price && reference_quantity && purchased_quantity && conversion_ratio

        exact_amount = price * purchased_quantity * conversion_ratio / reference_quantity
        projected_amount = round_value(exact_amount, "round")
        return nil unless projected_amount.between?(0, MAX_LINE_TOTAL)

        discount = project_discount(
          source_item: source,
          projected_amount: projected_amount,
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
        return nil if gross_amount && !gross_amount.between?(0, MAX_LINE_TOTAL)

        Projection.new(
          exact_reference_amount: exact_amount,
          projected_reference_line_total: projected_amount,
          discount_amount: discount,
          discounted_source_line_total: discounted_amount,
          projected_gross_line_total: gross_amount
        )
      rescue ArgumentError, TypeError, ZeroDivisionError, FloatDomainError, RangeError
        nil
      end

      def project_discount(source_item:, projected_amount:, rounding:)
        return nil unless source_item.is_a?(Hash)
        return nil unless projected_amount.is_a?(Integer) && projected_amount.between?(0, MAX_LINE_TOTAL)
        return nil unless %w[floor round ceil].include?(rounding)

        discount = projected_discount(source_item, projected_amount, rounding: rounding)
        discount if discount && discount.between?(0, projected_amount)
      rescue ArgumentError, TypeError, FloatDomainError, RangeError
        nil
      end

      def rounding_matches(exact_amount:, printed_line_total:)
        return [] if exact_amount.nil? || printed_line_total.nil?

        exact = bounded_exact_amount(exact_amount)
        printed = bounded_line_total_integer(printed_line_total)
        return [] unless exact && printed

        {
          "floor" => exact.floor,
          "half_up" => (exact + Rational(1, 2)).floor,
          "ceil" => exact.ceil
        }.filter_map { |mode, amount| mode if amount == printed }
      rescue ArgumentError, TypeError, FloatDomainError, RangeError
        []
      end

      private

      def exact_decimal(
        value,
        max_scale:,
        maximum:,
        allow_zero: false,
        allow_integer: false,
        allow_float: false
      )
        text = bounded_decimal_token(
          value,
          maximum: maximum,
          allow_integer: allow_integer,
          allow_float: allow_float
        )
        return nil unless text
        return nil unless text.match?(DECIMAL_PATTERN)
        return nil if text.include?(".") && text.split(".", 2).last.length > max_scale

        value = Rational(text)
        return nil if value.negative?
        return nil if value.zero? && !allow_zero
        return nil if value > maximum

        value
      end

      def bounded_decimal_token(value, maximum:, allow_integer:, allow_float:)
        case value
        when String
          return nil unless safe_token?(value)

          value
        when Integer
          return nil unless allow_integer
          return nil if value.negative? || value > maximum || value.bit_length > MAX_INTEGER_BITS

          value.to_s
        when Float
          return nil unless allow_float
          return nil unless value.finite? && value >= 0 && value <= maximum.to_f

          token = value.to_s
          safe_token?(token) ? token : nil
        else
          nil
        end
      end

      def safe_token?(value)
        return false if value.empty? || value.bytesize > EXACT_TOKEN_MAX_BYTES
        return false unless value.valid_encoding? && value.ascii_only?

        true
      rescue EncodingError
        false
      end

      def exact_conversion_ratio(from:, to:)
        return nil unless from.is_a?(String) && to.is_a?(String)
        return nil unless safe_token?(from) && safe_token?(to)

        from_dimension, from_scale = UNIT_SCALES[from]
        to_dimension, to_scale = UNIT_SCALES[to]
        return nil unless from_dimension && from_dimension == to_dimension

        from_scale / to_scale
      end

      def projected_discount(source, projected_amount, rounding:)
        if source.key?("discount_rate") && !source["discount_rate"].nil?
          rate = exact_decimal(
            source["discount_rate"],
            max_scale: 6,
            maximum: MAX_RATE,
            allow_zero: true
          )
          return nil unless rate

          round_value(projected_amount * rate, rounding)
        elsif source.key?("discount_amount") && !source["discount_amount"].nil?
          amount = exact_decimal(
            source["discount_amount"],
            max_scale: 0,
            maximum: Rational(MAX_LINE_TOTAL),
            allow_zero: true,
            allow_integer: true
          )
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
          rate = exact_decimal(
            tax_rate,
            max_scale: 6,
            maximum: MAX_RATE,
            allow_zero: true,
            allow_integer: true,
            allow_float: true
          )
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

      def bounded_exact_amount(value)
        exact = case value
        when Integer
          return nil if value.bit_length > MAX_EXACT_BITS

          Rational(value)
        when Rational
          return nil if value.numerator.bit_length > MAX_EXACT_BITS
          return nil if value.denominator.bit_length > MAX_EXACT_BITS

          value
        else
          return nil
        end
        return nil if exact.negative? || exact > Rational(MAX_LINE_TOTAL + 1)

        exact
      end

      def bounded_line_total_integer(value)
        case value
        when Integer
          value if value.between?(0, MAX_LINE_TOTAL)
        when String
          return nil unless safe_token?(value)
          return nil unless value.match?(/\A(?:0|[1-9]\d*)\z/)

          integer = Integer(value, 10)
          integer if integer <= MAX_LINE_TOTAL
        end
      end
    end
  end
end
