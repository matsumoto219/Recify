# frozen_string_literal: true

module Amounts
  class ExactBoundedDecimal
    MAX_INPUT_BYTES = 64
    MAX_COMPONENT_DIGITS = 64
    MAX_NUMERIC_BITS = 256
    MAX_DECIMAL_SCALE = 18
    DECIMAL_PATTERN = /\A[+-]?(\d+)(?:\.(\d+))?\z/.freeze

    def self.call(value, minimum:, maximum:, maximum_scale:, minimum_inclusive:)
      new(
        value,
        minimum: minimum,
        maximum: maximum,
        maximum_scale: maximum_scale,
        minimum_inclusive: minimum_inclusive
      ).call
    end

    def initialize(value, minimum:, maximum:, maximum_scale:, minimum_inclusive:)
      @value = value
      @minimum = minimum
      @maximum = maximum
      @maximum_scale = maximum_scale
      @minimum_inclusive = minimum_inclusive
    end

    def call
      return nil unless maximum_scale.is_a?(Integer) && maximum_scale.between?(0, MAX_DECIMAL_SCALE)

      exact = exact_value
      return nil unless exact && bounded_rational?(exact)
      return nil if minimum_inclusive ? exact < minimum : exact <= minimum
      return nil if exact > maximum
      return nil unless finite_decimal_scale_within_limit?(exact)

      exact
    rescue ArgumentError, TypeError, FloatDomainError, ZeroDivisionError
      nil
    end

    private

    attr_reader :value, :minimum, :maximum, :maximum_scale, :minimum_inclusive

    def exact_value
      case value
      when Integer
        value.to_r if bounded_integer?(value)
      when Rational
        value if bounded_rational?(value)
      when BigDecimal
        exact_big_decimal
      when String
        exact_string
      end
    end

    def exact_big_decimal
      return nil unless value.finite?
      return nil if value.precision > MAX_COMPONENT_DIGITS
      return nil if value.exponent.abs > MAX_COMPONENT_DIGITS

      value.to_r
    end

    def exact_string
      return nil if value.bytesize > MAX_INPUT_BYTES
      return nil unless value.valid_encoding? && value.ascii_only?

      match = DECIMAL_PATTERN.match(value)
      return nil unless match
      return nil if match[1].bytesize > MAX_COMPONENT_DIGITS
      return nil if match[2]&.bytesize.to_i > MAX_COMPONENT_DIGITS

      Rational(value)
    end

    def bounded_integer?(integer)
      integer.abs.bit_length <= MAX_NUMERIC_BITS
    end

    def bounded_rational?(rational)
      bounded_integer?(rational.numerator) && rational.denominator.bit_length <= MAX_NUMERIC_BITS
    end

    def finite_decimal_scale_within_limit?(exact)
      denominator = exact.denominator
      twos = bounded_factor_count(denominator, 2)
      return false unless twos

      denominator /= 2**twos
      fives = bounded_factor_count(denominator, 5)
      return false unless fives

      denominator /= 5**fives
      denominator == 1 && [ twos, fives ].max <= maximum_scale
    end

    def bounded_factor_count(number, factor)
      count = 0
      while (number % factor).zero?
        count += 1
        return nil if count > maximum_scale

        number /= factor
      end
      count
    end
  end
end
