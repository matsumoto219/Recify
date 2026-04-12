module Ai
  module Errors
    class ProviderError < StandardError
      attr_reader :error_code, :provider, :cause

      def initialize(message: nil, error_code: nil, provider: nil, cause: nil)
        super(message || default_message(error_code, provider))
        @error_code = error_code
        @provider = provider
        @cause = cause
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
