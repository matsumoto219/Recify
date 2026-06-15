# frozen_string_literal: true

module Amounts
  module NumberParser
    module_function

    def parse_amount(value, default: 0)
      return default if blank?(value)

      BigDecimal(normalize_amount_text(value)).round(0).to_i
    rescue ArgumentError
      default
    end

    def parse_amount_or_nil(value)
      return nil if blank?(value)

      parse_amount(value, default: nil)
    end

    def parse_quantity(value, default: BigDecimal("0"))
      return default if blank?(value)

      BigDecimal(normalize_quantity_text(value))
    rescue ArgumentError
      default
    end

    def parse_quantity_or_nil(value)
      return nil if blank?(value)

      parse_quantity(value, default: nil)
    end

    def normalize_amount_text(value)
      normalize_numeric_text(value)
        .delete(",")
        .gsub(/[^0-9.-]/, "")
        .gsub(/(?!^)-/, "")
        .then { |text| normalize_decimal_points(text) }
    end

    def normalize_quantity_text(value)
      text = normalize_numeric_text(value)
      comma_count = text.count(",")

      text =
        if !text.include?(".") && comma_count == 1
          text.sub(",", ".")
        else
          text.delete(",")
        end

      text
        .gsub(/[^0-9.-]/, "")
        .gsub(/(?!^)-/, "")
        .then { |normalized| normalize_decimal_points(normalized) }
    end

    def normalize_numeric_text(value)
      value.to_s
        .tr("０-９", "0-9")
        .tr("．，－", ".,-")
    end

    def normalize_decimal_points(text)
      parts = text.split(".")
      return text if parts.size <= 2

      [ parts.first, parts[1..].join ].join(".")
    end

    def blank?(value)
      value.nil? || value == ""
    end
  end
end
