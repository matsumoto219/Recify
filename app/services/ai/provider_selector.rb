module Ai
  class ProviderSelector
    DEFAULT_PRIMARY_PROVIDER = "openai".freeze

    class << self
      def primary
        normalize_provider_name(ENV.fetch("AI_PRIMARY_PROVIDER", DEFAULT_PRIMARY_PROVIDER))
      end

      def fallback
        value = ENV["AI_FALLBACK_PROVIDER"]
        return nil if value.blank?

        normalize_provider_name(value)
      end

      private

      def normalize_provider_name(value)
        value.to_s.strip.downcase.presence
      end
    end
  end
end
