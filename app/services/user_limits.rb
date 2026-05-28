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

    def override_for(user:, key:, override_cache: nil)
      return unless user

      definition = definition_for(key)
      return override_cache[definition.key] if override_cache

      user.user_limit_overrides
          .active
          .find_by(key: definition.key)
    end

    def effective_limit(user:, key:)
      entry_for(user: user, key: key).value
    end

    def entry_for(user:, key:, override_cache: nil, system_limit_cache: nil)
      definition = definition_for(key)
      override = override_for(user: user, key: definition.key, override_cache: override_cache)

      if override
        return Entry.new(
          key: definition.key,
          value: override.integer_value,
          source: "override",
          definition: definition,
          override: override,
          global_value: global_value_for(definition, system_limit_cache: system_limit_cache),
          base_value: base_value_for(user, definition),
          api_reservation: definition.api_reservation == true
        )
      end

      value, source = fallback_value_and_source(user, definition, system_limit_cache: system_limit_cache)

      Entry.new(
        key: definition.key,
        value: value,
        source: source,
        definition: definition,
        override: nil,
        global_value: global_value_for(definition, system_limit_cache: system_limit_cache),
        base_value: base_value_for(user, definition),
        api_reservation: definition.api_reservation == true
      )
    end

    def summary_for(user:)
      override_cache = active_override_cache_for(user)
      system_limit_cache = system_limit_cache_for_summary

      definitions.keys.map do |key|
        entry_for(user: user, key: key, override_cache: override_cache, system_limit_cache: system_limit_cache)
      end
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

    def fallback_value_and_source(user, definition, system_limit_cache: nil)
      if definition.storage
        storage_fallback(user, system_limit_cache: system_limit_cache)
      elsif user&.guest? && definition.guest_system_setting_key.present?
        [ system_limit_for(definition.guest_system_setting_key, system_limit_cache: system_limit_cache), "guest_global_default" ]
      else
        [ global_value_for(definition, system_limit_cache: system_limit_cache), "global_default" ]
      end
    end

    def storage_fallback(user, system_limit_cache: nil)
      base_value = Integer(user.storage_limit_bytes)
      return [ base_value, "user_storage_limit" ] unless user.guest?

      guest_global_value = system_limit_for("limits.guest_storage_bytes", system_limit_cache: system_limit_cache)
      [ [ base_value, guest_global_value ].min, "guest_global_default" ]
    end

    def global_value_for(definition, system_limit_cache: nil)
      return unless definition.system_setting_key

      system_limit_for(definition.system_setting_key, system_limit_cache: system_limit_cache)
    end

    def system_limit_for(key, system_limit_cache: nil)
      return system_limit_cache.fetch(key) if system_limit_cache&.key?(key)

      SystemSettings.limit_for(key)
    end

    def active_override_cache_for(user)
      return {} unless user

      user.user_limit_overrides
          .active
          .where(key: definitions.keys)
          .index_by(&:key)
    end

    def system_limit_cache_for_summary
      keys = definitions.values.flat_map do |definition|
        [ definition.system_setting_key, definition.guest_system_setting_key ]
      end.compact.uniq

      SystemSettings.limits_for(keys)
    end

    def base_value_for(user, definition)
      return Integer(user.storage_limit_bytes) if definition.storage

      nil
    end
  end
end
