module Ai
  class ProviderRegistry
    class << self
      def fetch(provider_name)
        normalized_name = normalize_provider_name(provider_name)

        case normalized_name
        when "openai"
          Ai::Providers::Openai::Client.new
        when nil
          raise ArgumentError, "ai provider is not configured"
        else
          raise NotImplementedError, "ai provider is not implemented: #{normalized_name}"
        end
      end

      private

      def normalize_provider_name(value)
        value.to_s.strip.downcase.presence
      end
    end
  end
end
