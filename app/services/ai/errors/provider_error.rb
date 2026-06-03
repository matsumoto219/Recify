module Ai
  module Errors
    class ProviderError < StandardError
      attr_reader :error_code, :provider, :cause, :retry_after, :metrics

      def initialize(message: nil, error_code: nil, provider: nil, cause: nil, retry_after: nil, metrics: nil)
        super(message || default_message(error_code, provider))
        @error_code = error_code
        @provider = provider
        @cause = cause
        @retry_after = retry_after
        @metrics = Ai::ProviderMetrics.build(metrics)
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
