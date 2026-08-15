# frozen_string_literal: true

class Receipts::NumericInput
  MAX_PERCENTAGE = BigDecimal("100")
  private_constant :MAX_PERCENTAGE

  TAX_RATE_MAX_SCALE = 4
  DISCOUNT_RATE_MAX_SCALE = 3

  class InvalidValue < StandardError
    def initialize
      super("Invalid user numeric input")
    end
  end

  class << self
    def integer(value)
      return nil if blank_input?(value)

      UserNumericInput.integer(value, signed: false)
    rescue UserNumericInput::InvalidValue
      raise InvalidValue
    end

    def decimal(value)
      return nil if blank_input?(value)

      UserNumericInput.decimal(value, signed: false, decimal_comma: true)
    rescue UserNumericInput::InvalidValue
      raise InvalidValue
    end

    def grouped_decimal(value)
      return nil if blank_input?(value)

      UserNumericInput.decimal(value, signed: false, decimal_comma: false)
    rescue UserNumericInput::InvalidValue
      raise InvalidValue
    end

    def percentage(value, maximum_rate_scale: nil)
      parsed = decimal(value)
      raise InvalidValue if parsed && parsed > MAX_PERCENTAGE

      rate = parsed && parsed / MAX_PERCENTAGE
      validate_rate_scale!(rate, maximum_rate_scale)
      rate
    end

    def tax_percentage(value)
      percentage(value, maximum_rate_scale: TAX_RATE_MAX_SCALE)
    end

    def discount_percentage(value)
      percentage(value, maximum_rate_scale: DISCOUNT_RATE_MAX_SCALE)
    end

    # Receipt-level input has historically accepted either a decimal rate
    # (0.1) or a percentage-like value (10). Preserve that shape for the
    # Amount boundary while rejecting values its decimal column would round.
    def receipt_tax_rate(value)
      parsed = decimal(value)
      persisted_rate = parsed && (parsed > 1 ? parsed / MAX_PERCENTAGE : parsed)
      validate_rate_scale!(persisted_rate, TAX_RATE_MAX_SCALE)
      parsed
    end

    private

    def blank_input?(value)
      return true if value.nil?
      return false unless value.is_a?(String)
      return false if value.bytesize > UserNumericInput::MAX_INPUT_BYTES
      return false unless value.valid_encoding?

      value.strip.empty?
    rescue EncodingError
      false
    end

    def validate_rate_scale!(rate, maximum_rate_scale)
      return if rate.nil? || maximum_rate_scale.nil? || rate.scale <= maximum_rate_scale

      raise InvalidValue
    end
  end
end
