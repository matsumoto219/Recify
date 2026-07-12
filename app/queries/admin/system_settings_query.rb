module Admin
  class SystemSettingsQuery
    Result = Data.define(:records, :total_count)
    CATEGORY_ORDER = %w[
      operation
      security
      maintenance
      usage_limit
      usage_limit_safety
      amount_limit
      snapshot_limit
      ai_prompt_limit
      analysis_quality
      analysis_artifact
      upload_limit
      retention
      storage_policy
      storage_warning
      external_service_status
      external_service_tuning
      security_event
      amount_engine
      ui_toggle
      ui_notice
      feature_flag
      soft_limit
    ].freeze

    class << self
      def call(**filters)
        new(**filters).call
      end

      def find(key:)
        new(key: key).call.records.first
      end
    end

    def initialize(key: nil, category: nil, editable: nil, risk_level: nil)
      @key = normalize_filter(key)
      @category = normalize_filter(category)
      @editable = normalize_filter(editable)
      @risk_level = normalize_filter(risk_level)
    end

    def call
      records = definitions.filter_map do |definition|
        next unless include_definition?(definition)

        build_record(definition)
      end

      Result.new(records: records, total_count: records.size)
    end

    private

    attr_reader :key, :category, :editable, :risk_level

    def definitions
      SystemSettings.definitions.values.sort_by { |definition| [ category_order(definition.category), definition.key ] }
    end

    def category_order(category)
      CATEGORY_ORDER.index(category) || CATEGORY_ORDER.length
    end

    def include_definition?(definition)
      return false if key.present? && definition.key != key
      return false if category.present? && definition.category != category
      return false if risk_level.present? && definition.risk_level != risk_level
      return false if editable.present? && definition.editable.to_s != editable

      true
    end

    def build_record(definition)
      entry = SystemSettings.fetch(definition.key)

      {
        key: definition.key,
        category: definition.category,
        value_type: definition.value_type,
        default_value: safe_value(entry.default_value),
        current_value: safe_value(entry.current_value),
        source: entry.source,
        editable: definition.editable,
        risk_level: definition.risk_level,
        min: definition.min,
        max: definition.max,
        allowed_values: definition.allowed_values,
        requires_confirmation: definition.requires_confirmation == true || definition.risk_level.to_s == "high",
        updated_by_user: entry.updated_by_user,
        updated_by_user_id: entry.updated_by_user&.id,
        updated_at: entry.updated_at,
        definition: definition.to_h
      }
    end

    def safe_value(value)
      AuditLogs.sanitize(value)
    end

    def normalize_filter(value)
      value.to_s.strip.presence
    end
  end
end
