module ExternalServices
  class RuntimeConfig
    SCHEMA_VERSION = 1
    AI_EXECUTION_CONFIG_VERSION = 1
    DEFAULT_OPENAI_MODEL = "gpt-6-luna".freeze
    REASONING_SETTING_KEYS = %w[
      external_services.ai.reasoning_effort
      external_services.ai.name_completion_reasoning_effort
    ].freeze
    AI_EXECUTION_KEYS = %w[model reasoning_effort name_completion_reasoning_effort].freeze

    AIConfig = Data.define(
      :open_timeout_seconds,
      :read_timeout_seconds,
      :max_elapsed_seconds,
      :max_retries,
      :base_retry_delay_seconds,
      :max_retry_delay_seconds,
      :model,
      :reasoning_effort,
      :name_completion_reasoning_effort
    ) do
      def initialize(model: nil, reasoning_effort: nil, name_completion_reasoning_effort: nil, **timing)
        super(**timing, model:, reasoning_effort:, name_completion_reasoning_effort:)
      end
    end

    OCRConfig = Data.define(
      :request_timeout_seconds,
      :max_elapsed_seconds,
      :max_poll_attempts,
      :poll_interval_seconds,
      :poll_backoff_factor,
      :max_poll_interval_seconds,
      :max_retries,
      :base_retry_delay_seconds,
      :max_retry_delay_seconds
    )

    Snapshot = Data.define(:schema_version, :ai, :ocr) do
      def serializable_hash
        {
          "schema_version" => schema_version,
          "ai" => ai.to_h.compact.transform_keys(&:to_s),
          "ocr" => ocr.to_h.transform_keys(&:to_s),
          "ai_execution_config_version" => ai.model.nil? ? nil : AI_EXECUTION_CONFIG_VERSION
        }.compact
      end
    end

    class << self
      def openai_model_name(env: ENV)
        value = env["OPENAI_AI_MODEL"]
        raise ArgumentError, "invalid_ai_model" unless value.nil? || value.is_a?(String)

        model_value(value&.strip.presence || DEFAULT_OPENAI_MODEL)
      end

      def load(legacy_snapshot: nil)
        keys = legacy_snapshot ? REASONING_SETTING_KEYS : SystemSettings::EXTERNAL_SERVICE_RUNTIME_TUNING_KEYS + REASONING_SETTING_KEYS
        values = SystemSettings.values_for(keys)
        if legacy_snapshot
          return legacy_snapshot.with(ai: legacy_snapshot.ai.with(**ai_execution_values(values)))
        end

        build_snapshot(values)
      end

      def deserialize(value)
        snapshot = value.to_h.with_indifferent_access
        raise ArgumentError, "invalid_runtime_config_schema" unless snapshot[:schema_version].to_i == SCHEMA_VERSION

        ai_values = snapshot.fetch(:ai).to_h.with_indifferent_access
        ocr_values = snapshot.fetch(:ocr).to_h.with_indifferent_access
        execution_values = deserialize_ai_execution(snapshot, ai_values)

        Snapshot.new(
          schema_version: SCHEMA_VERSION,
          ai: AIConfig.new(
            open_timeout_seconds: Integer(ai_values.fetch(:open_timeout_seconds)),
            read_timeout_seconds: Integer(ai_values.fetch(:read_timeout_seconds)),
            max_elapsed_seconds: Integer(ai_values.fetch(:max_elapsed_seconds)),
            max_retries: Integer(ai_values.fetch(:max_retries)),
            base_retry_delay_seconds: Float(ai_values.fetch(:base_retry_delay_seconds)),
            max_retry_delay_seconds: Float(ai_values.fetch(:max_retry_delay_seconds)),
            **execution_values
          ),
          ocr: OCRConfig.new(
            request_timeout_seconds: Integer(ocr_values.fetch(:request_timeout_seconds)),
            max_elapsed_seconds: Integer(ocr_values.fetch(:max_elapsed_seconds)),
            max_poll_attempts: Integer(ocr_values.fetch(:max_poll_attempts)),
            poll_interval_seconds: Float(ocr_values.fetch(:poll_interval_seconds)),
            poll_backoff_factor: Float(ocr_values.fetch(:poll_backoff_factor)),
            max_poll_interval_seconds: Float(ocr_values.fetch(:max_poll_interval_seconds)),
            max_retries: Integer(ocr_values.fetch(:max_retries)),
            base_retry_delay_seconds: Float(ocr_values.fetch(:base_retry_delay_seconds)),
            max_retry_delay_seconds: Float(ocr_values.fetch(:max_retry_delay_seconds))
          )
        )
      end

      private

      def build_snapshot(values)
        normalized = values.to_h.with_indifferent_access

        Snapshot.new(
          schema_version: SCHEMA_VERSION,
          ai: AIConfig.new(
            open_timeout_seconds: integer_value(normalized, "external_services.ai.open_timeout_seconds", :open_timeout_seconds),
            read_timeout_seconds: integer_value(normalized, "external_services.ai.read_timeout_seconds", :read_timeout_seconds),
            max_elapsed_seconds: integer_value(normalized, "external_services.ai.max_elapsed_seconds", :max_elapsed_seconds),
            max_retries: integer_value(normalized, "external_services.ai.max_retries", :max_retries),
            base_retry_delay_seconds: decimal_value(normalized, "external_services.ai.base_retry_delay_seconds", :base_retry_delay_seconds),
            max_retry_delay_seconds: decimal_value(normalized, "external_services.ai.max_retry_delay_seconds", :max_retry_delay_seconds),
            **ai_execution_values(normalized)
          ),
          ocr: OCRConfig.new(
            request_timeout_seconds: integer_value(normalized, "external_services.ocr.request_timeout_seconds", :request_timeout_seconds),
            max_elapsed_seconds: integer_value(normalized, "external_services.ocr.max_elapsed_seconds", :max_elapsed_seconds),
            max_poll_attempts: integer_value(normalized, "external_services.ocr.max_poll_attempts", :max_poll_attempts),
            poll_interval_seconds: decimal_value(normalized, "external_services.ocr.poll_interval_seconds", :poll_interval_seconds),
            poll_backoff_factor: decimal_value(normalized, "external_services.ocr.poll_backoff_factor", :poll_backoff_factor),
            max_poll_interval_seconds: decimal_value(normalized, "external_services.ocr.max_poll_interval_seconds", :max_poll_interval_seconds),
            max_retries: integer_value(normalized, "external_services.ocr.max_retries", :max_retries),
            base_retry_delay_seconds: decimal_value(normalized, "external_services.ocr.base_retry_delay_seconds", :base_retry_delay_seconds),
            max_retry_delay_seconds: decimal_value(normalized, "external_services.ocr.max_retry_delay_seconds", :max_retry_delay_seconds)
          )
        )
      end

      def ai_execution_values(values)
        {
          model: openai_model_name,
          reasoning_effort: effort_value(values.fetch(REASONING_SETTING_KEYS.first), REASONING_SETTING_KEYS.first),
          name_completion_reasoning_effort: effort_value(values.fetch(REASONING_SETTING_KEYS.last), REASONING_SETTING_KEYS.last)
        }
      end

      def deserialize_ai_execution(snapshot, values)
        return {} if !snapshot.key?(:ai_execution_config_version) && AI_EXECUTION_KEYS.none? { |key| values.key?(key) }

        unless snapshot[:ai_execution_config_version] == AI_EXECUTION_CONFIG_VERSION && AI_EXECUTION_KEYS.all? { |key| values.key?(key) }
          raise ArgumentError, "invalid_ai_execution_config"
        end

        {
          model: model_value(values[:model]),
          reasoning_effort: effort_value(values[:reasoning_effort], REASONING_SETTING_KEYS.first),
          name_completion_reasoning_effort: effort_value(values[:name_completion_reasoning_effort], REASONING_SETTING_KEYS.last)
        }
      end

      def model_value(value)
        unless value.is_a?(String) && ErrorTextSanitizer.call(value, identifier: true) == value
          raise ArgumentError, "invalid_ai_model"
        end

        value.dup.freeze
      end

      def effort_value(value, key)
        unless value.is_a?(String) && SystemSettings.definition_for(key).allowed_values.include?(value)
          raise ArgumentError, "invalid_ai_reasoning_effort"
        end

        value.dup.freeze
      end

      def integer_value(values, setting_key, snapshot_key)
        Integer(fetch_value(values, setting_key, snapshot_key))
      end

      def decimal_value(values, setting_key, snapshot_key)
        Float(fetch_value(values, setting_key, snapshot_key))
      end

      def fetch_value(values, setting_key, snapshot_key)
        return values.fetch(setting_key) if values.key?(setting_key)

        values.fetch(snapshot_key)
      end
    end
  end
end
