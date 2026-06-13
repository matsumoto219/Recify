module Ai
  module Errors
    class TimeoutError < ProviderError
      def initialize(message: nil, provider: nil, category: :timeout, retryable: true, fallbackable: true, cause: nil, retry_after: nil, provider_status: "timeout", provider_error_code: nil, provider_error_type: nil, provider_message: nil, request_id: nil, quota_exceeded: nil, rate_limited: nil, auth_error: nil, phase: nil, metrics: nil)
        super(
          message: message || default_message(provider),
          error_code: "ai_timeout",
          provider: provider,
          category: category,
          retryable: retryable,
          fallbackable: fallbackable,
          cause: cause,
          retry_after: retry_after,
          provider_status: provider_status,
          provider_error_code: provider_error_code,
          provider_error_type: provider_error_type,
          provider_message: provider_message,
          request_id: request_id,
          quota_exceeded: quota_exceeded,
          rate_limited: rate_limited,
          auth_error: auth_error,
          phase: phase,
          metrics: metrics
        )
      end

      private

      def default_message(provider)
        base = "AI request timed out"
        base += " (provider: #{provider})" if provider
        base
      end
    end
  end
end
