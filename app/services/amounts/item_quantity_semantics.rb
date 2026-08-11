# frozen_string_literal: true

module Amounts
  class ItemQuantitySemantics
    class InvalidFormulaSourceError < ArgumentError; end
    class InvalidPackageContentError < ArgumentError; end

    attr_reader :purchased_quantity,
      :purchased_unit,
      :reference_quantity,
      :reference_unit,
      :package_content

    def initialize(
      purchased_quantity: nil,
      purchased_unit_code: nil,
      reference_quantity: nil,
      reference_unit_code: nil,
      package_content: nil
    )
      @purchased_quantity = immutable_quantity_copy(purchased_quantity)
      @purchased_unit = ReceiptQuantityUnit.resolve(purchased_unit_code)
      @reference_quantity = immutable_quantity_copy(reference_quantity)
      @reference_unit = ReceiptQuantityUnit.resolve(reference_unit_code)
      @package_content = immutable_package_content(package_content)
      freeze
    end

    def package_only?
      present?(package_content) &&
        !present?(purchased_quantity) &&
        purchased_unit.blank? &&
        !present?(reference_quantity) &&
        reference_unit.blank?
    end

    def reference_basis_complete?
      valid_quantity_for_role?(purchased_quantity, purchased_unit, :purchased) &&
        valid_quantity_for_role?(reference_quantity, reference_unit, :reference) &&
        ReceiptQuantityUnit.convertible?(from: purchased_unit.code, to: reference_unit.code)
    end

    def validate_count_formula!
      unit = resolved_unit(purchased_unit)
      valid = valid_quantity_for_role?(purchased_quantity, purchased_unit, :purchased) &&
        unit&.kind == :countable &&
        unit.allows_pricing_role?(:purchased)

      raise InvalidFormulaSourceError, "count formula requires an exact positive quantity and known countable unit" unless valid

      self
    end

    def validate_reference_formula!
      unless reference_basis_complete?
        raise InvalidFormulaSourceError,
          "reference formula requires exact positive quantities and compatible known units"
      end

      self
    end

    private

    def valid_quantity_for_role?(quantity, resolution, role)
      unit = resolved_unit(resolution)
      exact_quantity = exact_positive_quantity(quantity)
      return false unless unit&.allows_pricing_role?(role) && exact_quantity

      (exact_quantity / unit.input_granularity).denominator == 1
    end

    def resolved_unit(resolution)
      return nil unless resolution.known?

      ReceiptQuantityUnit.unit_for(resolution.code)
    end

    def present?(value)
      value.present?
    end

    def exact_positive_quantity(value)
      exact = case value
      when Integer, Rational
        value.to_r
      when BigDecimal
        value.to_r
      when String
        numeric = value.strip
        return nil unless numeric.match?(/\A\d+(?:\.\d+)?\z/)

        Rational(numeric)
      end

      exact if exact&.positive?
    rescue ArgumentError, FloatDomainError
      nil
    end

    def immutable_quantity_copy(value)
      return value.dup.freeze if value.is_a?(String)
      return value if value.nil? || immutable_numeric?(value)

      raise InvalidFormulaSourceError, "quantity source must use an immutable exact-capable scalar"
    end

    def immutable_package_content(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested_value), copy|
          copy[immutable_package_content(key)] = immutable_package_content(nested_value)
        end.freeze
      when Array
        value.map { |nested_value| immutable_package_content(nested_value) }.freeze
      when String
        value.dup.freeze
      when Symbol, Integer, Float, Rational, BigDecimal, TrueClass, FalseClass, NilClass
        value
      else
        raise InvalidPackageContentError, "package content must use immutable scalar, String, Array, or Hash values"
      end
    end

    def immutable_numeric?(value)
      value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(Rational) || value.is_a?(BigDecimal)
    end
  end
end
