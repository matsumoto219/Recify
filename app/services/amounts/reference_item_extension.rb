# frozen_string_literal: true

module Amounts
  class ReferenceItemExtension
    class InvalidSourceError < ArgumentError; end

    Result = Data.define(:exact_amount, :projected_amount, :reference_price_tax_inclusion)

    TAX_INCLUSION_BY_STRING = Amounts::ItemPricingSource::REFERENCE_PRICE_TAX_INCLUSIONS.to_h do |value|
      [ value.to_s.freeze, value ]
    end.freeze

    def self.call(
      reference_price_amount:,
      reference_quantity:,
      reference_unit_code:,
      purchased_quantity:,
      purchased_unit_code:,
      reference_price_tax_inclusion:
    )
      new(
        reference_price_amount: reference_price_amount,
        reference_quantity: reference_quantity,
        reference_unit_code: reference_unit_code,
        purchased_quantity: purchased_quantity,
        purchased_unit_code: purchased_unit_code,
        reference_price_tax_inclusion: reference_price_tax_inclusion
      ).call
    end

    def initialize(
      reference_price_amount:,
      reference_quantity:,
      reference_unit_code:,
      purchased_quantity:,
      purchased_unit_code:,
      reference_price_tax_inclusion:
    )
      @reference_price_amount = exact_nonnegative_amount(reference_price_amount)
      @quantity_semantics = Amounts::ItemQuantitySemantics.new(
        purchased_quantity: purchased_quantity,
        purchased_unit_code: canonical_unit_code!(purchased_unit_code),
        reference_quantity: reference_quantity,
        reference_unit_code: canonical_unit_code!(reference_unit_code)
      )
      @reference_price_tax_inclusion = normalize_tax_inclusion(reference_price_tax_inclusion)
      freeze
    end

    def call
      quantity_semantics.validate_reference_formula!

      purchased_in_reference_unit = ReceiptQuantityUnit.convert_exact(
        quantity_semantics.purchased_quantity,
        from: quantity_semantics.purchased_unit.code,
        to: quantity_semantics.reference_unit.code
      )
      exact_reference_quantity = ReceiptQuantityUnit.convert_exact(
        quantity_semantics.reference_quantity,
        from: quantity_semantics.reference_unit.code,
        to: quantity_semantics.reference_unit.code
      )
      exact_amount = reference_price_amount * purchased_in_reference_unit / exact_reference_quantity

      Result.new(
        exact_amount: exact_amount,
        projected_amount: project_to_integer_yen(exact_amount),
        reference_price_tax_inclusion: reference_price_tax_inclusion
      )
    end

    private

    attr_reader :reference_price_amount, :quantity_semantics, :reference_price_tax_inclusion

    def canonical_unit_code!(value)
      unit = ReceiptQuantityUnit.unit_for(value)
      return value if value.is_a?(String) && unit&.code == value

      raise Amounts::ItemQuantitySemantics::InvalidFormulaSourceError,
        "reference extension requires canonical unit codes"
    end

    def exact_nonnegative_amount(value)
      exact = case value
      when Integer, Rational
        value.to_r
      when BigDecimal
        value.to_r if value.finite?
      when String
        Rational(value) if value.match?(/\A[+-]?\d+(?:\.\d+)?\z/)
      end
      return exact if exact && !exact.negative?

      raise InvalidSourceError, "reference price amount must use an exact non-negative representation"
    rescue ArgumentError, TypeError, FloatDomainError, ZeroDivisionError
      raise InvalidSourceError, "reference price amount must use an exact non-negative representation"
    end

    def normalize_tax_inclusion(value)
      return value if Amounts::ItemPricingSource::REFERENCE_PRICE_TAX_INCLUSIONS.include?(value)
      return TAX_INCLUSION_BY_STRING[value] if value.is_a?(String) && TAX_INCLUSION_BY_STRING.key?(value)

      raise InvalidSourceError, "reference price tax inclusion must be gross or net"
    end

    def project_to_integer_yen(exact_amount)
      integer, remainder = exact_amount.numerator.divmod(exact_amount.denominator)
      integer + (remainder * 2 >= exact_amount.denominator ? 1 : 0)
    end
  end
end
