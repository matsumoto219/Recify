module Ai
  module Errors
    class ProviderError < StandardError
      attr_reader :error_code,
                  :provider,
                  :category,
                  :retryable,
                  :fallbackable,
                  :cause,
                  :retry_after,
                  :provider_status,
                  :provider_error_code,
                  :provider_error_type,
                  :provider_message,
                  :request_id,
                  :quota_exceeded,
                  :rate_limited,
                  :auth_error,
                  :phase,
                  :metrics

      def initialize(message: nil, error_code: nil, provider: nil, category: nil, retryable: false, fallbackable: false, cause: nil, retry_after: nil, provider_status: nil, provider_error_code: nil, provider_error_type: nil, provider_message: nil, request_id: nil, quota_exceeded: nil, rate_limited: nil, auth_error: nil, phase: nil, metrics: nil)
        super(message || default_message(error_code, provider))
        @error_code = error_code
        @provider = provider
        @category = category
        @retryable = retryable == true
        @fallbackable = fallbackable == true
        @cause = cause
        @retry_after = retry_after
        @provider_status = provider_status
        @provider_error_code = provider_error_code
        @provider_error_type = provider_error_type
        @provider_message = provider_message
        @request_id = request_id
        @quota_exceeded = optional_boolean(quota_exceeded)
        @rate_limited = optional_boolean(rate_limited)
        @auth_error = optional_boolean(auth_error)
        @phase = phase
        @metrics = Ai::ProviderMetrics.merge(
          metrics,
          provider: provider,
          provider_status: provider_status,
          provider_error_code: provider_error_code,
          provider_error_type: provider_error_type,
          provider_message: provider_message,
          request_id: request_id,
          retry_after: retry_after,
          quota_exceeded: quota_exceeded,
          rate_limited: rate_limited,
          auth_error: auth_error,
          phase: phase
        )
      end

      def retryable?
        retryable
      end

      def fallbackable?
        fallbackable
      end

      private

      def optional_boolean(value)
        return true if value == true
        return false if value == false

        nil
      end

      def default_message(error_code, provider)
        base = "AI provider error"
        base += " (provider: #{provider})" if provider
        base += " [#{error_code}]" if error_code
        base
      end
    end
  end
end
