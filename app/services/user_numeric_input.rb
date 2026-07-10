# frozen_string_literal: true

class UserNumericInput
  class InvalidValue < StandardError
    def initialize
      super("Invalid user numeric input")
    end
  end

  INTEGER_COMPONENT = /(?:\d+|\d{1,3}(?:,\d{3})+)/
  INTEGER_PATTERN = /\A[+-]?#{INTEGER_COMPONENT}\z/
  DECIMAL_PATTERN = /\A[+-]?(?:#{INTEGER_COMPONENT}(?:\.\d*)?|\.\d+)\z/

  class << self
    def integer(value, signed: true)
      text = normalize(value)
      raise InvalidValue unless text.match?(INTEGER_PATTERN)
      raise InvalidValue if !signed && signed_text?(text)

      Integer(text.delete(","), 10)
    rescue ArgumentError, TypeError
      raise InvalidValue
    end

    def decimal(value, signed: true, decimal_comma: false)
      text = normalize(value)
      text = text.sub(",", ".") if decimal_comma && !text.include?(".") && text.count(",") == 1
      raise InvalidValue unless text.match?(DECIMAL_PATTERN)
      raise InvalidValue if !signed && signed_text?(text)

      BigDecimal(text.delete(","))
    rescue ArgumentError, TypeError
      raise InvalidValue
    end

    private

    def signed_text?(text)
      text.start_with?("+", "-")
    end

    def normalize(value)
      text = value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s

      text
        .strip
        .tr("０-９", "0-9")
        .gsub("＋", "+")
        .gsub("－", "-")
        .gsub("．", ".")
        .gsub("，", ",")
    end
  end
end
