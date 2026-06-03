module Ai
  module Errors
    class TimeoutError < ProviderError
      def initialize(message: nil, provider: nil, category: :timeout, retryable: true, fallbackable: true, cause: nil, retry_after: nil, provider_status: "timeout", metrics: nil)
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
