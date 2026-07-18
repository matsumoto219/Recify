# frozen_string_literal: true

class Receipts::NumericInput
  MAX_PERCENTAGE = BigDecimal("100")
  private_constant :MAX_PERCENTAGE

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

    def percentage(value)
      parsed = decimal(value)
      raise InvalidValue, value if parsed && parsed > MAX_PERCENTAGE

      parsed && parsed / MAX_PERCENTAGE
    end
  end
end
