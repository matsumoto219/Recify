# frozen_string_literal: true

class Receipts::NumericInput
  MAX_PERCENTAGE = BigDecimal("100")
  private_constant :MAX_PERCENTAGE

  TAX_RATE_MAX_SCALE = 4
  DISCOUNT_RATE_MAX_SCALE = 3

  class InvalidValue < StandardError
    attr_reader :value

    def initialize(value)
      @value = value
      super("Invalid user numeric input")
    end
  end

  class << self
    def integer(value)
      return nil if value.to_s.strip.empty?

      UserNumericInput.integer(value, signed: false)
    rescue UserNumericInput::InvalidValue
      raise InvalidValue, value
    end

    def decimal(value)
      return nil if value.to_s.strip.empty?

      UserNumericInput.decimal(value, signed: false, decimal_comma: true)
    rescue UserNumericInput::InvalidValue
      raise InvalidValue, value
    end

    def grouped_decimal(value)
      return nil if value.to_s.strip.empty?

      UserNumericInput.decimal(value, signed: false, decimal_comma: false)
    rescue UserNumericInput::InvalidValue
      raise InvalidValue, value
    end

    def percentage(value, maximum_rate_scale: nil)
      parsed = decimal(value)
      raise InvalidValue, value if parsed && parsed > MAX_PERCENTAGE

      rate = parsed && parsed / MAX_PERCENTAGE
      validate_rate_scale!(rate, value, maximum_rate_scale)
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
      validate_rate_scale!(persisted_rate, value, TAX_RATE_MAX_SCALE)
      parsed
    end

    private

    def validate_rate_scale!(rate, raw_value, maximum_rate_scale)
      return if rate.nil? || maximum_rate_scale.nil? || rate.scale <= maximum_rate_scale

      raise InvalidValue, raw_value
    end
  end
end
