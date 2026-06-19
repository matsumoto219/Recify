module SystemSettings
  VALUE_KEY = "value"
  AMOUNT_LIMIT_DEFAULT = 999_999_999
  AMOUNT_LIMIT_CONFIGURABLE_MAX = 999_999_999_999
  AMOUNT_LIMIT_KEYS = %w[
    limits.receipt_total_amount_max
    limits.receipt_item_price_max
    limits.receipt_item_line_total_max
    limits.receipt_tax_amount_max
    limits.receipt_adjustment_amount_max
    limits.receipt_payment_amount_max
  ].freeze
  RECEIPT_ITEMS_LIMIT_KEY = "limits.receipt_items_per_receipt"
  RECEIPT_ITEMS_SNAPSHOT_LIMIT_ERROR = "receipt_items_snapshot_limit"
  USER_LIMIT_SAFETY_MAX_ERROR = "user_limit_safety_max"
  ANALYSIS_RUN_RETENTION_ORDER_ERROR = "analysis_run_retention_order"
  AMOUNT_LIMIT_RELATION_ERROR = "amount_limit_relationship"
  IMAGE_DIMENSION_RELATION_ERROR = "image_dimension_relationship"
  STORAGE_WARNING_THRESHOLD_RELATION_ERROR = "storage_warning_threshold_relationship"
  AMOUNT_LIMIT_RELATIONSHIPS = [
    [ "limits.receipt_total_amount_max", "limits.receipt_item_line_total_max" ],
    [ "limits.receipt_total_amount_max", "limits.receipt_adjustment_amount_max" ],
    [ "limits.receipt_total_amount_max", "limits.receipt_payment_amount_max" ],
    [ "limits.receipt_total_amount_max", "limits.receipt_tax_amount_max" ],
    [ "limits.receipt_item_line_total_max", "limits.receipt_item_price_max" ]
  ].freeze
  SNAPSHOT_RECEIPT_ITEMS_LIMIT_KEYS = %w[
    limits.snapshot_ocr_items_max
    limits.snapshot_ai_normalized_items_max
  ].freeze
  ANALYSIS_RUN_RETENTION_KEYS = %w[
    retention.analysis_runs_short_days
    retention.analysis_runs_default_days
    retention.analysis_runs_failed_days
  ].freeze
  IMAGE_DIMENSION_RELATIONSHIPS = [
    [ "limits.receipt_image_min_dimension_px", "limits.receipt_image_max_dimension_px" ],
    [ "limits.announcement_image_min_dimension_px", "limits.announcement_image_max_dimension_px" ]
  ].freeze
  IMAGE_DIMENSION_LIMIT_KEYS = IMAGE_DIMENSION_RELATIONSHIPS.flatten.freeze
  STORAGE_USAGE_PERCENTAGE_KEYS = %w[
    storage.usage_warning_percentage
    storage.usage_error_percentage
  ].freeze
  STORAGE_REMAINING_BYTES_KEYS = %w[
    storage.warning_remaining_bytes
    storage.error_remaining_bytes
  ].freeze
  USER_LIMIT_SETTING_SAFETY_KEYS = {
    "limits.receipt_uploads_per_day" => "limits.max_uploads_per_day",
    "limits.batch_files_per_day" => "limits.max_uploads_per_day",
    "limits.guest_receipt_uploads_per_day" => "limits.max_uploads_per_day",
    "limits.guest_batch_files_per_day" => "limits.max_uploads_per_day",
    "limits.ocr_jobs_per_day" => "limits.max_ocr_per_day",
    "limits.guest_ocr_jobs_per_day" => "limits.max_ocr_per_day",
    "limits.ai_jobs_per_day" => "limits.max_ai_per_day",
    "limits.guest_ai_jobs_per_day" => "limits.max_ai_per_day",
    "limits.guest_storage_bytes" => "limits.max_storage_bytes"
  }.freeze
  USER_LIMIT_SAFETY_SETTING_KEYS = USER_LIMIT_SETTING_SAFETY_KEYS.group_by { |_setting_key, safety_key| safety_key }
                                                                  .transform_values { |pairs| pairs.map(&:first) }
                                                                  .freeze
  USER_LIMIT_SAFETY_OVERRIDE_KEYS = {
    "limits.max_uploads_per_day" => %w[receipt_uploads_per_day batch_files_per_day],
    "limits.max_ocr_per_day" => %w[ocr_jobs_per_day],
    "limits.max_ai_per_day" => %w[ai_jobs_per_day],
    "limits.max_storage_bytes" => %w[storage_bytes]
  }.freeze

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
    :allowed_values,
    :requires_confirmation,
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
        max: max,
        allowed_values: allowed_values,
        requires_confirmation: requires_confirmation
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

    def value_for(key, user: nil, context: {})
      fetch(key).current_value
    end

    def values_for(keys)
      normalized_keys = Array(keys).map { |key| normalize_key(key) }.uniq
      definitions_by_key = normalized_keys.index_with { |key| definition_for(key) }
      settings_by_key = SystemSetting.where(key: normalized_keys).index_by(&:key)

      definitions_by_key.transform_values do |definition|
        setting = settings_by_key[definition.key]
        setting ? cast_stored_value(definition, setting.value) : definition.default
      end
    end

    def limits_for(keys)
      values = values_for(keys)

      values.each_with_object({}) do |(key, value), limits|
        definition = definition_for(key)
        limits[key] =
          begin
            Integer(value)
          rescue ArgumentError, TypeError
            Integer(definition.default)
          end
      end
    end

    def enabled?(key, user: nil, context: {})
      definition = definition_for(key)
      value = value_for(key, user: user, context: context)

      case definition.value_type.to_s
      when "boolean"
        value == true
      when "feature_flag"
        rollout_enabled?(key, user: user, context: context)
      else
        raise ValidationError, "not_boolean_setting"
      end
    end

    def rollout_enabled?(key, user:, context: {})
      definition = definition_for(key)
      raise ValidationError, "not_feature_flag" unless definition.value_type.to_s == "feature_flag"

      flag_value = normalize_feature_flag_value(value_for(key, user: user, context: context))
      return false unless flag_value.fetch("enabled")
      return true if user_allowlisted?(flag_value.fetch("user_allowlist"), user)

      percentage = flag_value.fetch("rollout_percentage")
      return false if percentage <= 0
      return true if percentage >= 100
      return false unless user&.id

      rollout_bucket(key: definition.key, user_id: user.id) < percentage
    end

    def limit_for(key, user: nil, context: {})
      value = value_for(key, user: user, context: context)
      Integer(value)
    rescue ArgumentError, TypeError
      definition = definition_for(key)

      Integer(definition.default)
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

      casted_value = cast_value(definition, stored_raw_value(value))
      validate_setting_dependencies!(definition, casted_value)
      true
    end

    def stored_value(value)
      { VALUE_KEY => value }
    end

    def cast_update_value(key, value)
      definition = definition_for(key)
      casted_value = cast_value(definition, value)
      validate_setting_dependencies!(definition, casted_value)
      casted_value
    end

    def stored_value_for_update(key, value)
      casted_value = cast_update_value(key, value)

      stored_value(serializable_value(casted_value))
    end

    def audit_value(value)
      case value
      when BigDecimal
        value.to_s("F")
      when Array
        value.map { |child| audit_value(child) }
      when Hash
        value.transform_values { |child| audit_value(child) }
      else
        value
      end
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
      when "decimal"
        cast_decimal(definition, value)
      when "string"
        cast_string(definition, value)
      when "enum"
        cast_enum(definition, value)
      when "percentage"
        cast_percentage(definition, value)
      when "user_allowlist"
        cast_user_allowlist(value)
      when "duration"
        cast_duration(definition, value)
      when "feature_flag"
        cast_feature_flag(value)
      else
        value
      end
    end

    def cast_boolean(value)
      return value if value == true || value == false
      return true if %w[true 1 on yes].include?(value.to_s)
      return false if %w[false 0 off no].include?(value.to_s)

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

    def cast_decimal(definition, value)
      decimal = BigDecimal(value.to_s)
      validate_numeric_range!(definition, decimal)

      decimal
    rescue ArgumentError, TypeError
      raise ValidationError, "invalid_decimal"
    end

    def cast_string(definition, value)
      string = value.to_s
      raise ValidationError, "above_max" if definition.max && string.length > definition.max

      string
    end

    def cast_enum(definition, value)
      enum_value = value.to_s
      allowed_values = Array(definition.allowed_values).map(&:to_s)
      raise ValidationError, "invalid_enum" if allowed_values.empty? || !allowed_values.include?(enum_value)

      enum_value
    end

    def cast_percentage(definition, value)
      percentage = BigDecimal(value.to_s)
      min = definition.min || 0
      max = definition.max || 100
      raise ValidationError, "below_min" if percentage < BigDecimal(min.to_s)
      raise ValidationError, "above_max" if percentage > BigDecimal(max.to_s)

      percentage
    rescue ArgumentError, TypeError
      raise ValidationError, "invalid_percentage"
    end

    def cast_user_allowlist(value)
      values =
        case value
        when Array
          value
        else
          value.to_s.split(/[\s,]+/)
        end

      values.map { |entry| entry.to_s.strip }.reject(&:blank?).uniq
    end

    def cast_duration(definition, value)
      seconds =
        if value.is_a?(Hash)
          duration_value = value["value"] || value[:value]
          unit = (value["unit"] || value[:unit] || "seconds").to_s

          Integer(duration_value) * duration_unit_multiplier(unit)
        else
          Integer(value)
        end
      raise ValidationError, "below_min" if definition.min && seconds < definition.min
      raise ValidationError, "above_max" if definition.max && seconds > definition.max

      seconds
    rescue ArgumentError, TypeError
      raise ValidationError, "invalid_duration"
    end

    def duration_unit_multiplier(unit)
      case unit
      when "seconds" then 1
      when "minutes" then 60
      when "hours" then 3600
      when "days" then 86_400
      else
        raise ValidationError, "invalid_duration_unit"
      end
    end

    def validate_numeric_range!(definition, value)
      raise ValidationError, "below_min" if definition.min && value < BigDecimal(definition.min.to_s)
      raise ValidationError, "above_max" if definition.max && value > BigDecimal(definition.max.to_s)
    end

    def validate_setting_dependencies!(definition, value)
      validate_receipt_items_snapshot_dependency!(definition, value)
      validate_user_limit_setting_safety!(definition, value)
      validate_user_limit_safety_ceiling!(definition, value)
      validate_analysis_run_retention_order!(definition, value)
      validate_amount_limit_relationships!(definition, value)
      validate_image_dimension_relationships!(definition, value)
      validate_storage_warning_threshold_relationships!(definition, value)
    end

    def validate_receipt_items_snapshot_dependency!(definition, value)
      return unless definition.key == RECEIPT_ITEMS_LIMIT_KEY
      return if Integer(value) <= receipt_items_snapshot_ceiling

      raise ValidationError, RECEIPT_ITEMS_SNAPSHOT_LIMIT_ERROR
    end

    def receipt_items_snapshot_ceiling
      limits_for(SNAPSHOT_RECEIPT_ITEMS_LIMIT_KEYS).values.min
    rescue UnknownKeyError, ValidationError, ArgumentError, TypeError
      1000
    end

    def validate_user_limit_setting_safety!(definition, value)
      safety_key = USER_LIMIT_SETTING_SAFETY_KEYS[definition.key]
      return unless safety_key
      return if Integer(value) <= limit_for(safety_key)

      raise ValidationError, USER_LIMIT_SAFETY_MAX_ERROR
    end

    def validate_user_limit_safety_ceiling!(definition, value)
      return unless USER_LIMIT_SAFETY_SETTING_KEYS.key?(definition.key)

      safety_limit = Integer(value)
      validate_related_system_limits!(definition.key, safety_limit)
      validate_related_user_limit_overrides!(definition.key, safety_limit)
    end

    def validate_related_system_limits!(safety_key, safety_limit)
      current_limits = limits_for(USER_LIMIT_SAFETY_SETTING_KEYS.fetch(safety_key))
      return if current_limits.values.all? { |limit| limit <= safety_limit }

      raise ValidationError, USER_LIMIT_SAFETY_MAX_ERROR
    end

    def validate_related_user_limit_overrides!(safety_key, safety_limit)
      keys = USER_LIMIT_SAFETY_OVERRIDE_KEYS.fetch(safety_key)
      has_exceeding_override = UserLimitOverride.active
                                             .where(key: keys)
                                             .any? { |override| override_integer_value(override) > safety_limit }
      return unless has_exceeding_override

      raise ValidationError, USER_LIMIT_SAFETY_MAX_ERROR
    end

    def validate_analysis_run_retention_order!(definition, value)
      return unless ANALYSIS_RUN_RETENTION_KEYS.include?(definition.key)

      values = limits_for(ANALYSIS_RUN_RETENTION_KEYS)
      values[definition.key] = Integer(value)

      short_days = values.fetch("retention.analysis_runs_short_days")
      default_days = values.fetch("retention.analysis_runs_default_days")
      failed_days = values.fetch("retention.analysis_runs_failed_days")
      return if failed_days >= default_days && default_days >= short_days

      raise ValidationError, ANALYSIS_RUN_RETENTION_ORDER_ERROR
    end

    def validate_amount_limit_relationships!(definition, value)
      return unless AMOUNT_LIMIT_KEYS.include?(definition.key)

      values = limits_for(AMOUNT_LIMIT_KEYS)
      values[definition.key] = Integer(value)

      invalid_relationship = AMOUNT_LIMIT_RELATIONSHIPS.any? do |parent_key, child_key|
        values.fetch(parent_key) < values.fetch(child_key)
      end
      return unless invalid_relationship

      raise ValidationError, AMOUNT_LIMIT_RELATION_ERROR
    end

    def validate_image_dimension_relationships!(definition, value)
      return unless IMAGE_DIMENSION_LIMIT_KEYS.include?(definition.key)

      values = limits_for(IMAGE_DIMENSION_LIMIT_KEYS)
      values[definition.key] = Integer(value)

      invalid_relationship = IMAGE_DIMENSION_RELATIONSHIPS.any? do |min_key, max_key|
        values.fetch(min_key) > values.fetch(max_key)
      end
      return unless invalid_relationship

      raise ValidationError, IMAGE_DIMENSION_RELATION_ERROR
    end

    def validate_storage_warning_threshold_relationships!(definition, value)
      if STORAGE_USAGE_PERCENTAGE_KEYS.include?(definition.key)
        validate_storage_usage_percentage_relationship!(definition, value)
      elsif STORAGE_REMAINING_BYTES_KEYS.include?(definition.key)
        validate_storage_remaining_bytes_relationship!(definition, value)
      end
    end

    def validate_storage_usage_percentage_relationship!(definition, value)
      values = limits_for(STORAGE_USAGE_PERCENTAGE_KEYS)
      values[definition.key] = Integer(value)
      return if values.fetch("storage.usage_warning_percentage") < values.fetch("storage.usage_error_percentage")

      raise ValidationError, STORAGE_WARNING_THRESHOLD_RELATION_ERROR
    end

    def validate_storage_remaining_bytes_relationship!(definition, value)
      values = limits_for(STORAGE_REMAINING_BYTES_KEYS)
      values[definition.key] = Integer(value)
      return if values.fetch("storage.warning_remaining_bytes") > values.fetch("storage.error_remaining_bytes")

      raise ValidationError, STORAGE_WARNING_THRESHOLD_RELATION_ERROR
    end

    def override_integer_value(override)
      Integer(override.value.fetch(VALUE_KEY))
    rescue ArgumentError, KeyError, TypeError
      0
    end

    def serializable_value(value)
      case value
      when BigDecimal
        value.to_s("F")
      when Hash
        value.transform_values { |child| serializable_value(child) }
      when Array
        value.map { |child| serializable_value(child) }
      else
        value
      end
    end

    def cast_feature_flag(value)
      raw = feature_flag_hash(value)
      enabled = cast_boolean(raw.fetch("enabled", false))
      rollout_percentage = cast_feature_flag_percentage(raw.fetch("rollout_percentage", 0))
      user_allowlist = cast_user_allowlist(raw.fetch("user_allowlist", []))

      {
        "enabled" => enabled,
        "rollout_percentage" => rollout_percentage,
        "user_allowlist" => user_allowlist
      }
    end

    def feature_flag_hash(value)
      return value.deep_stringify_keys if value.is_a?(Hash)
      return JSON.parse(value).deep_stringify_keys if value.is_a?(String)

      raise ValidationError, "invalid_feature_flag"
    rescue JSON::ParserError
      raise ValidationError, "invalid_feature_flag"
    end

    def cast_feature_flag_percentage(value)
      percentage = BigDecimal(value.to_s)
      raise ValidationError, "below_min" if percentage < 0
      raise ValidationError, "above_max" if percentage > 100

      percentage.to_i == percentage ? percentage.to_i : percentage
    rescue ArgumentError, TypeError
      raise ValidationError, "invalid_percentage"
    end

    def normalize_feature_flag_value(value)
      cast_feature_flag(value)
    end

    def user_allowlisted?(allowlist, user)
      return false unless user&.id

      Array(allowlist).map(&:to_s).include?(user.id.to_s)
    end

    def rollout_bucket(key:, user_id:)
      Digest::SHA256.hexdigest("#{key}:#{user_id}").to_i(16) % 100
    end
  end
end
