module SystemSettings
  VALUE_KEY = "value"

  UnknownKeyError = Class.new(KeyError)
  ValidationError = Class.new(StandardError)

  Definition = Struct.new(
    :key,
    :category,
    :value_type,
    :default,
    :editable,
    :risk_level,
    :min,
    :max,
    keyword_init: true
  ) do
    def to_h
      {
        key: key,
        category: category,
        value_type: value_type,
        default: default,
        editable: editable,
        risk_level: risk_level,
        min: min,
        max: max
      }.compact
    end
  end

  Entry = Struct.new(
    :definition,
    :setting,
    :current_value,
    :default_value,
    :source,
    :updated_by_user,
    :updated_at,
    keyword_init: true
  )

  class << self
    def definitions
      Definitions.all
    end

    def definition_for(key)
      definitions.fetch(normalize_key(key))
    rescue KeyError
      raise UnknownKeyError, "Unknown system setting key=#{key}"
    end

    def fetch(key)
      definition = definition_for(key)
      setting = SystemSetting.includes(:updated_by_user).find_by(key: definition.key)

      Entry.new(
        definition: definition,
        setting: setting,
        current_value: setting ? cast_stored_value(definition, setting.value) : definition.default,
        default_value: definition.default,
        source: setting ? "db" : "default",
        updated_by_user: setting&.updated_by_user,
        updated_at: setting&.updated_at
      )
    end

    def value_for(key, context: {})
      fetch(key).current_value
    end

    def source_for(key)
      fetch(key).source
    end

    def editable?(key)
      definition_for(key).editable == true
    end

    def valid_key?(key)
      definitions.key?(normalize_key(key))
    end

    def validate_stored_value!(key, value)
      definition = definition_for(key)
      raise ValidationError, "must_be_hash" unless value.is_a?(Hash)
      raise ValidationError, "value_required" unless value.key?(VALUE_KEY) || value.key?(VALUE_KEY.to_sym)

      cast_value(definition, stored_raw_value(value))
      true
    end

    def stored_value(value)
      { VALUE_KEY => value }
    end

    private

    def normalize_key(key)
      key.to_s.strip
    end

    def cast_stored_value(definition, stored_value)
      cast_value(definition, stored_raw_value(stored_value))
    end

    def stored_raw_value(stored_value)
      return unless stored_value.is_a?(Hash)

      return stored_value[VALUE_KEY] if stored_value.key?(VALUE_KEY)

      stored_value[VALUE_KEY.to_sym]
    end

    def cast_value(definition, value)
      case definition.value_type.to_s
      when "boolean"
        cast_boolean(value)
      when "integer"
        cast_integer(definition, value)
      else
        value
      end
    end

    def cast_boolean(value)
      return value if value == true || value == false
      return true if value.to_s == "true"
      return false if value.to_s == "false"

      raise ValidationError, "invalid_boolean"
    end

    def cast_integer(definition, value)
      integer = Integer(value)
      raise ValidationError, "below_min" if definition.min && integer < definition.min
      raise ValidationError, "above_max" if definition.max && integer > definition.max

      integer
    rescue ArgumentError, TypeError
      raise ValidationError, "invalid_integer"
    end
  end
end
