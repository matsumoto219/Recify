# frozen_string_literal: true

class ReceiptUserNumericInput
  class InvalidValue < StandardError
    attr_reader :value

    def initialize(value)
      @value = value
      super("Invalid user numeric input")
    end
  end

  UNSIGNED_INTEGER_PATTERN = /\A(?:\d+|\d{1,3}(?:,\d{3})+)\z/
  UNSIGNED_DECIMAL_PATTERN = /\A(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d+)?\z/

  class << self
    def integer(value)
      text = normalize(value)
      return nil if text.empty?

      raise InvalidValue, value unless text.match?(UNSIGNED_INTEGER_PATTERN)

      Integer(text.delete(","), 10)
    rescue ArgumentError
      raise InvalidValue, value
    end

    def decimal(value)
      text = normalize(value)
      return nil if text.empty?

      text = text.sub(",", ".") if !text.include?(".") && text.count(",") == 1

      raise InvalidValue, value unless text.match?(UNSIGNED_DECIMAL_PATTERN)

      BigDecimal(text.delete(","))
    rescue ArgumentError
      raise InvalidValue, value
    end

    def percentage(value)
      parsed = decimal(value)
      parsed && parsed / 100
    end

    private

    def normalize(value)
      value.to_s
        .strip
        .tr("０-９", "0-9")
        .tr("．，", ".,")
    end
  end
end
