module UserLimits
  VALUE_KEY = "value"

  ValidationError = Class.new(StandardError)

  Definition = Struct.new(
    :key,
    :system_setting_key,
    :min,
    :max,
    :storage,
    :api_reservation,
    :guest_system_setting_key,
    keyword_init: true
  )

  Entry = Struct.new(
    :key,
    :value,
    :source,
    :definition,
    :override,
    :global_value,
    :base_value,
    :api_reservation,
    keyword_init: true
  )

  DEFINITIONS = [
    Definition.new(
      key: "receipt_uploads_per_day",
      system_setting_key: "limits.receipt_uploads_per_day",
      guest_system_setting_key: "limits.guest_receipt_uploads_per_day",
      min: 1,
      max: 1000
    ),
    Definition.new(
      key: "batch_files_per_day",
      system_setting_key: "limits.batch_files_per_day",
      guest_system_setting_key: "limits.guest_batch_files_per_day",
      min: 1,
      max: 1000
    ),
    Definition.new(
      key: "ocr_jobs_per_day",
      system_setting_key: "limits.ocr_jobs_per_day",
      guest_system_setting_key: "limits.guest_ocr_jobs_per_day",
      min: 1,
      max: 1000
    ),
    Definition.new(
      key: "ai_jobs_per_day",
      system_setting_key: "limits.ai_jobs_per_day",
      guest_system_setting_key: "limits.guest_ai_jobs_per_day",
      min: 1,
      max: 1000
    ),
    Definition.new(
      key: "retry_operations_per_day",
      system_setting_key: "limits.retry_operations_per_day",
      min: 1,
      max: 200
    ),
    Definition.new(
      key: "storage_bytes",
      min: 1.megabyte,
      max: 100.gigabytes,
      storage: true
    ),
    Definition.new(
      key: "api_requests_per_minute",
      system_setting_key: "limits.api_requests_per_minute",
      min: 1,
      max: 1000,
      api_reservation: true
    ),
    Definition.new(
      key: "api_requests_per_day",
      system_setting_key: "limits.api_requests_per_day",
      min: 1,
      max: 100_000,
      api_reservation: true
    )
  ].index_by(&:key).freeze

  class << self
    def definitions
      DEFINITIONS
    end

    def definition_for(key)
      definitions.fetch(normalize_key(key))
    rescue KeyError
      raise ValidationError, "unknown_key"
    end

    def valid_key?(key)
      definitions.key?(normalize_key(key))
    end

    def override_for(user:, key:)
      return unless user

      user.user_limit_overrides
          .active
          .find_by(key: definition_for(key).key)
    end

    def effective_limit(user:, key:)
      entry_for(user: user, key: key).value
    end

    def entry_for(user:, key:)
      definition = definition_for(key)
      override = override_for(user: user, key: definition.key)

      if override
        return Entry.new(
          key: definition.key,
          value: override.integer_value,
          source: "override",
          definition: definition,
          override: override,
          global_value: global_value_for(definition),
          base_value: base_value_for(user, definition),
          api_reservation: definition.api_reservation == true
        )
      end

      value, source = fallback_value_and_source(user, definition)

      Entry.new(
        key: definition.key,
        value: value,
        source: source,
        definition: definition,
        override: nil,
        global_value: global_value_for(definition),
        base_value: base_value_for(user, definition),
        api_reservation: definition.api_reservation == true
      )
    end

    def summary_for(user:)
      definitions.keys.map { |key| entry_for(user: user, key: key) }
    end

    def cast_value(key, value)
      definition = definition_for(key)
      raw_value = raw_value_from(value)
      integer = Integer(raw_value)
      raise ValidationError, "below_min" if definition.min && integer < definition.min
      raise ValidationError, "above_max" if definition.max && integer > definition.max

      integer
    rescue ArgumentError, TypeError
      raise ValidationError, "invalid_integer"
    end

    def stored_value(value)
      { VALUE_KEY => cast_value_for_storage(value) }
    end

    private

    def normalize_key(key)
      key.to_s.strip
    end

    def raw_value_from(value)
      return value[VALUE_KEY] if value.is_a?(Hash) && value.key?(VALUE_KEY)
      return value[VALUE_KEY.to_sym] if value.is_a?(Hash) && value.key?(VALUE_KEY.to_sym)

      value
    end

    def cast_value_for_storage(value)
      Integer(raw_value_from(value))
    rescue ArgumentError, TypeError
      value
    end

    def fallback_value_and_source(user, definition)
      if definition.storage
        storage_fallback(user)
      elsif user&.guest? && definition.guest_system_setting_key.present?
        [ SystemSettings.limit_for(definition.guest_system_setting_key), "guest_global_default" ]
      else
        [ global_value_for(definition), "global_default" ]
      end
    end

    def storage_fallback(user)
      base_value = Integer(user.storage_limit_bytes)
      return [ base_value, "user_storage_limit" ] unless user.guest?

      guest_global_value = SystemSettings.limit_for("limits.guest_storage_bytes")
      [ [ base_value, guest_global_value ].min, "guest_global_default" ]
    end

    def global_value_for(definition)
      return unless definition.system_setting_key

      SystemSettings.limit_for(definition.system_setting_key)
    end

    def base_value_for(user, definition)
      return Integer(user.storage_limit_bytes) if definition.storage

      nil
    end
  end
end
