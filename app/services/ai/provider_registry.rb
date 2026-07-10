module Ai
  class ProviderRegistry
    class << self
      def fetch(provider_name, runtime_config: nil)
        normalized_name = normalize_provider_name(provider_name)

        case normalized_name
        when "openai"
          Ai::Providers::Openai::Client.new(runtime_config: runtime_config)
        when nil
          raise ArgumentError, "ai provider is not configured"
        else
          raise NotImplementedError, "ai provider is not implemented: #{normalized_name}"
        end
      end

      def implemented?(provider_name)
        normalize_provider_name(provider_name) == "openai"
      end

      private

      def normalize_provider_name(value)
        value.to_s.strip.downcase.presence
      end
    end
  end
end
