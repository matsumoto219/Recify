module Ai
  module Errors
    class TimeoutError < ProviderError
      def initialize(message: nil, provider: nil, cause: nil)
        super(
          message: message || default_message(provider),
          error_code: "ai_timeout",
          provider: provider,
          cause: cause
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
