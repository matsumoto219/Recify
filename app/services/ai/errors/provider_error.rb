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
                  :metrics

      def initialize(message: nil, error_code: nil, provider: nil, category: nil, retryable: false, fallbackable: false, cause: nil, retry_after: nil, provider_status: nil, metrics: nil)
        super(message || default_message(error_code, provider))
        @error_code = error_code
        @provider = provider
        @category = category
        @retryable = retryable == true
        @fallbackable = fallbackable == true
        @cause = cause
        @retry_after = retry_after
        @provider_status = provider_status
        @metrics = Ai::ProviderMetrics.merge(
          metrics,
          provider: provider,
          provider_status: provider_status
        )
      end

      def retryable?
        retryable
      end

      def fallbackable?
        fallbackable
      end

      private

      def default_message(error_code, provider)
        base = "AI provider error"
        base += " (provider: #{provider})" if provider
        base += " [#{error_code}]" if error_code
        base
      end
    end
  end
end
