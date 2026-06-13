module Ai
  class ProviderMetrics
    METADATA_KEY = "recify_ai_metrics".freeze
    TOKEN_USAGE_KEYS = %i[
      input_tokens
      output_tokens
      total_tokens
      prompt_tokens
      completion_tokens
    ].freeze

    class << self
      def build(values = {})
        sanitize(values)
      end

      def merge(metrics, values = {})
        sanitize(normalized_hash(metrics).merge(normalized_hash(values).compact))
      end

      def sanitize(value)
        metrics = normalized_hash(value)

        {
          provider: safe_string(metrics[:provider]),
          model: safe_string(metrics[:model]),
          final_provider: safe_string(metrics[:final_provider]),
          elapsed_ms: safe_numeric(metrics[:elapsed_ms]),
          retry_count: safe_numeric(metrics[:retry_count]),
          retry_after_used: safe_boolean(metrics, :retry_after_used),
          total_retry_sleep_ms: safe_numeric(metrics[:total_retry_sleep_ms]),
          rate_limited: safe_boolean(metrics, :rate_limited),
          provider_status: safe_string(metrics[:provider_status]),
          provider_error_code: safe_string(metrics[:provider_error_code]),
          provider_error_type: safe_string(metrics[:provider_error_type]),
          provider_message: safe_message(metrics[:provider_message]),
          request_id: safe_string(metrics[:request_id]),
          retry_after: safe_numeric(metrics[:retry_after]),
          quota_exceeded: safe_boolean(metrics, :quota_exceeded),
          auth_error: safe_boolean(metrics, :auth_error),
          phase: safe_string(metrics[:phase]),
          token_usage: token_usage(metrics[:token_usage]).presence,
          response_id: safe_string(metrics[:response_id]),
          fallback_used: safe_boolean(metrics, :fallback_used),
          fallback_provider: safe_string(metrics[:fallback_provider]),
          fallback_reason: safe_string(metrics[:fallback_reason])
        }.compact
      end

      def token_usage(value)
        usage = normalized_hash(value)

        TOKEN_USAGE_KEYS.each_with_object({}) do |key, memo|
          numeric = safe_numeric(usage[key])
          memo[key] = numeric unless numeric.nil?
        end
      end

      private

      def normalized_hash(value)
        return value.with_indifferent_access if value.respond_to?(:with_indifferent_access)

        {}.with_indifferent_access
      end

      def safe_string(value)
        value.to_s.presence if value.present?
      end

      def safe_message(value)
        message = safe_string(value)
        return if message.blank?

        message
          .gsub(/Bearer\s+[A-Za-z0-9._\-]+/i, "[FILTERED]")
          .gsub(/\bsk-[A-Za-z0-9_\-]{10,}\b/i, "[FILTERED]")
      end

      def safe_numeric(value)
        return value if value.is_a?(Numeric)
        return value.to_f if value.to_s.match?(/\A-?\d+(?:\.\d+)?\z/)

        nil
      end

      def safe_boolean(values, key)
        return unless values.key?(key)

        values[key] == true
      end
    end
  end
end
