# frozen_string_literal: true

class ReceiptCalculationSettings
  SCHEMA_VERSION = 1
  MAX_SERIALIZED_BYTES = 4_096
  ROUNDING_MODES = %w[floor round ceil].freeze
  ROUNDING_SCOPES = %w[per_item per_tax_rate_group per_receipt].freeze
  TAX_INCLUSIONS = %w[gross net].freeze
  ORIGINS = %w[manual form_default application_default analysis legacy_record].freeze
  SETTING_VALUES = {
    "tax_rounding_mode" => ROUNDING_MODES,
    "discount_rounding_mode" => ROUNDING_MODES,
    "tax_rounding_scope" => ROUNDING_SCOPES,
    "purchase_adjustment_tax_inclusion" => TAX_INCLUSIONS
  }.freeze
  ROOT_KEYS = ([ "schema_version" ] + SETTING_VALUES.keys).freeze
  ENTRY_KEYS = %w[value origin].freeze

  class << self
    def parse(value)
      return unless value.is_a?(Hash) && value.size.between?(2, ROOT_KEYS.size)
      return unless allowed_keys?(value, ROOT_KEYS)
      return unless value["schema_version"].is_a?(Integer) && value["schema_version"] == SCHEMA_VERSION

      attributes = { "schema_version" => SCHEMA_VERSION }
      SETTING_VALUES.each do |key, allowed_values|
        next unless value.key?(key)

        entry = value[key]
        return unless valid_entry?(entry, allowed_values)

        attributes[key] = {
          "value" => entry["value"].encode(Encoding::UTF_8).freeze,
          "origin" => entry["origin"].encode(Encoding::UTF_8).freeze
        }.freeze
      end
      return if JSON.generate(attributes).bytesize > MAX_SERIALIZED_BYTES

      new(attributes.freeze)
    end

    private

    def allowed_keys?(value, allowed)
      value.each_key.all? { |key| allowed_token?(key, allowed) }
    end

    def valid_entry?(entry, allowed_values)
      entry.is_a?(Hash) &&
        entry.size == ENTRY_KEYS.size &&
        allowed_keys?(entry, ENTRY_KEYS) &&
        allowed_token?(entry["value"], allowed_values) &&
        allowed_token?(entry["origin"], ORIGINS)
    end

    def allowed_token?(value, allowed)
      value.is_a?(String) &&
        value.bytesize <= MAX_SERIALIZED_BYTES &&
        value.encoding.ascii_compatible? &&
        value.valid_encoding? &&
        allowed.include?(value)
    end
  end
  private_class_method :new

  def initialize(attributes)
    @attributes = attributes
    freeze
  end

  def value_for(key)
    return unless SETTING_VALUES.key?(key)

    @attributes.dig(key, "value")
  end

  def origin_for(key)
    return unless SETTING_VALUES.key?(key)

    @attributes.dig(key, "origin")
  end

  def to_h
    @attributes.deep_dup
  end
end
