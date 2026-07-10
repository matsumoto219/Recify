module ExternalServices
  class RuntimeConfig
    SCHEMA_VERSION = 1

    AIConfig = Data.define(
      :open_timeout_seconds,
      :read_timeout_seconds,
      :max_elapsed_seconds,
      :max_retries,
      :base_retry_delay_seconds,
      :max_retry_delay_seconds
    )

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
          "ai" => ai.to_h.transform_keys(&:to_s),
          "ocr" => ocr.to_h.transform_keys(&:to_s)
        }
      end
    end

    class << self
      def load
        values = SystemSettings.values_for(SystemSettings::EXTERNAL_SERVICE_RUNTIME_TUNING_KEYS)

        build_snapshot(values)
      end

      def deserialize(value)
        snapshot = value.to_h.with_indifferent_access
        raise ArgumentError, "invalid_runtime_config_schema" unless snapshot[:schema_version].to_i == SCHEMA_VERSION

        ai_values = snapshot.fetch(:ai).to_h.with_indifferent_access
        ocr_values = snapshot.fetch(:ocr).to_h.with_indifferent_access

        Snapshot.new(
          schema_version: SCHEMA_VERSION,
          ai: AIConfig.new(
            open_timeout_seconds: Integer(ai_values.fetch(:open_timeout_seconds)),
            read_timeout_seconds: Integer(ai_values.fetch(:read_timeout_seconds)),
            max_elapsed_seconds: Integer(ai_values.fetch(:max_elapsed_seconds)),
            max_retries: Integer(ai_values.fetch(:max_retries)),
            base_retry_delay_seconds: Float(ai_values.fetch(:base_retry_delay_seconds)),
            max_retry_delay_seconds: Float(ai_values.fetch(:max_retry_delay_seconds))
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
            max_retry_delay_seconds: decimal_value(normalized, "external_services.ai.max_retry_delay_seconds", :max_retry_delay_seconds)
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
