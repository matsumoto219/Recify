class ReceiptQuantityUnit
  Unit = Data.define(:code, :legacy_labels, :kind)

  DEFAULT_CODE = "each"

  UNITS = [
    Unit.new(code: "each", legacy_labels: %w[個], kind: :countable),
    Unit.new(code: "item", legacy_labels: %w[点], kind: :countable),
    Unit.new(code: "piece", legacy_labels: %w[本], kind: :countable),
    Unit.new(code: "bag", legacy_labels: %w[袋], kind: :countable),
    Unit.new(code: "sheet", legacy_labels: %w[枚], kind: :countable),
    Unit.new(code: "unit", legacy_labels: %w[台], kind: :countable),
    Unit.new(code: "box", legacy_labels: %w[箱], kind: :countable),
    Unit.new(code: "set", legacy_labels: %w[セット], kind: :countable),
    Unit.new(code: "gram", legacy_labels: %w[g グラム], kind: :decimal),
    Unit.new(code: "kilogram", legacy_labels: %w[kg キログラム], kind: :decimal),
    Unit.new(code: "milligram", legacy_labels: %w[mg ミリグラム], kind: :decimal),
    Unit.new(code: "liter", legacy_labels: %w[L l リットル], kind: :decimal),
    Unit.new(code: "milliliter", legacy_labels: %w[ml mL ミリリットル], kind: :decimal),
    Unit.new(code: "cubic_centimeter", legacy_labels: %w[cc], kind: :decimal)
  ].freeze

  ALLOWED_CODES = UNITS.map(&:code).freeze
  COUNTABLE_CODES = UNITS.select { |unit| unit.kind == :countable }.map(&:code).freeze
  DECIMAL_CODES = UNITS.select { |unit| unit.kind == :decimal }.map(&:code).freeze
  LEGACY_LABEL_TO_CODE = UNITS.each_with_object({}) do |unit, mapping|
    unit.legacy_labels.each { |label| mapping[label] = unit.code }
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

    def normalize(value, default: DEFAULT_CODE)
      normalized = value.to_s.strip
      return default if normalized.blank?
      return normalized if ALLOWED_CODES.include?(normalized)

      LEGACY_LABEL_TO_CODE.fetch(normalized, default)
    end

    def label(code, locale: I18n.locale)
      normalized = normalize(code)

      I18n.t("enums.receipt_item.quantity_unit.#{normalized}", locale: locale, default: normalized)
    end

    def options(locale: I18n.locale)
      ALLOWED_CODES.map { |code| [ label(code, locale: locale), code ] }
    end

    def option_entries(locale: I18n.locale)
      ALLOWED_CODES.map { |code| { value: code, label: label(code, locale: locale) } }
    end

    def legacy_label(code)
      unit = unit_for(code)

      unit&.legacy_labels&.first || label(code, locale: :ja)
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

    def unit_for(code)
      normalized = normalize(code)

      UNITS.find { |unit| unit.code == normalized }
    end
  end
end
