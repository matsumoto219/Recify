# frozen_string_literal: true

class ReceiptQuantityUnit
  class ConversionError < ArgumentError; end

  class UnknownUnitError < ConversionError; end

  class IncompatibleConversionError < ConversionError; end

  class InvalidExactQuantityError < ConversionError; end

  Unit = Data.define(
    :code,
    :input_aliases,
    :kind,
    :dimension,
    :conversion_group,
    :exact_scale,
    :input_granularity,
    :allowed_pricing_roles
  ) do
    def allows_pricing_role?(role)
      allowed_pricing_roles.include?(role.to_sym)
    end
  end

  Resolution = Data.define(:status, :code, :raw) do
    def known?
      status == :known
    end

    def blank?
      status == :blank
    end

    def unknown?
      status == :unknown
    end
  end

  DEFAULT_CODE = "each"
  PRICING_ROLES = %i[purchased reference].freeze
  COUNTABLE_GRANULARITY = Rational(1).freeze
  MEASUREMENT_GRANULARITY = Rational(1, 1_000).freeze

  UNITS = [
    Unit.new(
      code: "each", input_aliases: %w[個].freeze, kind: :countable,
      dimension: :count, conversion_group: "count:each", exact_scale: Rational(1),
      input_granularity: COUNTABLE_GRANULARITY, allowed_pricing_roles: PRICING_ROLES
    ),
    Unit.new(
      code: "item", input_aliases: %w[点].freeze, kind: :countable,
      dimension: :count, conversion_group: "count:item", exact_scale: Rational(1),
      input_granularity: COUNTABLE_GRANULARITY, allowed_pricing_roles: PRICING_ROLES
    ),
    Unit.new(
      code: "piece", input_aliases: %w[本].freeze, kind: :countable,
      dimension: :count, conversion_group: "count:piece", exact_scale: Rational(1),
      input_granularity: COUNTABLE_GRANULARITY, allowed_pricing_roles: PRICING_ROLES
    ),
    Unit.new(
      code: "bag", input_aliases: %w[袋].freeze, kind: :countable,
      dimension: :count, conversion_group: "count:bag", exact_scale: Rational(1),
      input_granularity: COUNTABLE_GRANULARITY, allowed_pricing_roles: PRICING_ROLES
    ),
    Unit.new(
      code: "sheet", input_aliases: %w[枚].freeze, kind: :countable,
      dimension: :count, conversion_group: "count:sheet", exact_scale: Rational(1),
      input_granularity: COUNTABLE_GRANULARITY, allowed_pricing_roles: PRICING_ROLES
    ),
    Unit.new(
      code: "unit", input_aliases: %w[台].freeze, kind: :countable,
      dimension: :count, conversion_group: "count:unit", exact_scale: Rational(1),
      input_granularity: COUNTABLE_GRANULARITY, allowed_pricing_roles: PRICING_ROLES
    ),
    Unit.new(
      code: "box", input_aliases: %w[箱].freeze, kind: :countable,
      dimension: :count, conversion_group: "count:box", exact_scale: Rational(1),
      input_granularity: COUNTABLE_GRANULARITY, allowed_pricing_roles: PRICING_ROLES
    ),
    Unit.new(
      code: "set", input_aliases: %w[セット].freeze, kind: :countable,
      dimension: :count, conversion_group: "count:set", exact_scale: Rational(1),
      input_granularity: COUNTABLE_GRANULARITY, allowed_pricing_roles: PRICING_ROLES
    ),
    Unit.new(
      code: "gram", input_aliases: %w[g グラム].freeze, kind: :decimal,
      dimension: :mass, conversion_group: "mass", exact_scale: Rational(1),
      input_granularity: MEASUREMENT_GRANULARITY, allowed_pricing_roles: PRICING_ROLES
    ),
    Unit.new(
      code: "kilogram", input_aliases: %w[kg キログラム].freeze, kind: :decimal,
      dimension: :mass, conversion_group: "mass", exact_scale: Rational(1_000),
      input_granularity: MEASUREMENT_GRANULARITY, allowed_pricing_roles: PRICING_ROLES
    ),
    Unit.new(
      code: "milligram", input_aliases: %w[mg ミリグラム].freeze, kind: :decimal,
      dimension: :mass, conversion_group: "mass", exact_scale: Rational(1, 1_000),
      input_granularity: MEASUREMENT_GRANULARITY, allowed_pricing_roles: PRICING_ROLES
    ),
    Unit.new(
      code: "liter", input_aliases: %w[L l リットル].freeze, kind: :decimal,
      dimension: :volume, conversion_group: "volume", exact_scale: Rational(1_000),
      input_granularity: MEASUREMENT_GRANULARITY, allowed_pricing_roles: PRICING_ROLES
    ),
    Unit.new(
      code: "milliliter", input_aliases: %w[ml mL ミリリットル].freeze, kind: :decimal,
      dimension: :volume, conversion_group: "volume", exact_scale: Rational(1),
      input_granularity: MEASUREMENT_GRANULARITY, allowed_pricing_roles: PRICING_ROLES
    ),
    Unit.new(
      code: "cubic_centimeter", input_aliases: %w[cc].freeze, kind: :decimal,
      dimension: :volume, conversion_group: "volume", exact_scale: Rational(1),
      input_granularity: MEASUREMENT_GRANULARITY, allowed_pricing_roles: PRICING_ROLES
    )
  ].freeze

  UNIT_BY_CODE = UNITS.to_h { |unit| [ unit.code, unit ] }.freeze
  ALLOWED_CODES = UNITS.map(&:code).freeze
  COUNTABLE_CODES = UNITS.select { |unit| unit.kind == :countable }.map(&:code).freeze
  DECIMAL_CODES = UNITS.select { |unit| unit.kind == :decimal }.map(&:code).freeze
  INPUT_ALIAS_TO_CODE = UNITS.each_with_object({}) do |unit, mapping|
    unit.input_aliases.each { |input_alias| mapping[input_alias] = unit.code }
  end.freeze

  class << self
    def allowed_codes
      ALLOWED_CODES
    end

    def countable_codes
      COUNTABLE_CODES
    end

    def decimal_codes
      DECIMAL_CODES
    end

    def default_code
      DEFAULT_CODE
    end

    def unit_for(code)
      UNIT_BY_CODE[code.to_s]
    end

    def resolve(value, aliases: INPUT_ALIAS_TO_CODE)
      raw = value.to_s.strip.freeze
      return Resolution.new(status: :blank, code: nil, raw: raw) if raw.empty?

      unit = unit_for(raw) || unit_for(aliases[raw])
      return Resolution.new(status: :known, code: unit.code, raw: raw) if unit

      Resolution.new(status: :unknown, code: nil, raw: raw)
    end

    def convertible?(from:, to:)
      from_unit = unit_for(from)
      to_unit = unit_for(to)

      !from_unit.nil? && !to_unit.nil? && from_unit.conversion_group == to_unit.conversion_group
    end

    def exact_conversion_ratio(from:, to:)
      from_unit = fetch_unit!(from)
      to_unit = fetch_unit!(to)

      unless from_unit.conversion_group == to_unit.conversion_group
        raise IncompatibleConversionError,
          "incompatible quantity unit conversion: #{from_unit.code.inspect} -> #{to_unit.code.inspect}"
      end

      from_unit.exact_scale / to_unit.exact_scale
    end

    def convert_exact(quantity, from:, to:)
      exact_quantity(quantity) * exact_conversion_ratio(from: from, to: to)
    end

    def normalize(value, default: DEFAULT_CODE, aliases: INPUT_ALIAS_TO_CODE)
      normalized = value.to_s.strip
      return default if normalized.blank?
      return normalized if ALLOWED_CODES.include?(normalized)

      aliases.fetch(normalized, default)
    end

    def label(code, locale: I18n.locale)
      normalized = normalize(code)

      I18n.t("enums.receipt_item.quantity_unit_code.#{normalized}", locale: locale, default: normalized)
    end

    def options(locale: I18n.locale)
      ALLOWED_CODES.map { |code| [ label(code, locale: locale), code ] }
    end

    def option_entries(locale: I18n.locale)
      ALLOWED_CODES.map { |code| { value: code, label: label(code, locale: locale) } }
    end

    def countable?(code)
      COUNTABLE_CODES.include?(normalize(code))
    end

    def decimal?(code)
      DECIMAL_CODES.include?(normalize(code))
    end

    def step_for(code)
      decimal?(code) ? "0.001" : "1"
    end

    def inputmode_for(code)
      decimal?(code) ? "decimal" : "numeric"
    end

    private

    def fetch_unit!(code)
      unit_for(code) || raise(UnknownUnitError, "unknown quantity unit: #{code.inspect}")
    end

    def exact_quantity(quantity)
      return quantity if quantity.is_a?(Rational)
      return Rational(quantity, 1) if quantity.is_a?(Integer)
      return quantity.to_r if defined?(BigDecimal) && quantity.is_a?(BigDecimal)
      return Rational(quantity) if quantity.is_a?(String)

      raise InvalidExactQuantityError, "quantity must use an exact numeric representation"
    rescue ArgumentError, TypeError, FloatDomainError, ZeroDivisionError
      raise InvalidExactQuantityError, "quantity must use an exact numeric representation"
    end
  end
end
