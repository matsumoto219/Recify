# frozen_string_literal: true

class UserNumericInput
  MAX_INPUT_BYTES = 128
  MAX_INTEGER_BITS = MAX_INPUT_BYTES * 4
  private_constant :MAX_INTEGER_BITS

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
      text = bounded_scalar_text(value)

      normalized = text
        .strip
        .tr("０-９", "0-9")
        .gsub("＋", "+")
        .gsub("－", "-")
        .gsub("．", ".")
        .gsub("，", ",")
      raise InvalidValue if normalized.bytesize > MAX_INPUT_BYTES

      normalized
    rescue EncodingError
      raise InvalidValue
    end

    def bounded_scalar_text(value)
      case value
      when String
        raise InvalidValue if value.bytesize > MAX_INPUT_BYTES
        raise InvalidValue unless value.valid_encoding?

        value
      when Integer
        raise InvalidValue if value.bit_length > MAX_INTEGER_BITS

        value.to_s
      when BigDecimal
        raise InvalidValue unless value.finite?
        raise InvalidValue if value.precision > MAX_INPUT_BYTES
        raise InvalidValue if value.exponent.abs > MAX_INPUT_BYTES

        value.to_s("F")
      when Float
        raise InvalidValue unless value.finite?

        value.to_s
      else
        raise InvalidValue
      end
    end
  end
end
