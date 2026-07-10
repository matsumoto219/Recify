module Ai
  class AvailabilityChecker
    OPERATION_SETTING_KEY = "operations.ai_enabled".freeze
    OPERATION_ENV_KEY = ReceiptAnalysisPipeline.ai_enabled_env_key
    PROVIDER_CONFIG = {
      "openai" => {
        api_key_env: "OPENAI_API_KEY",
        model_env: "OPENAI_AI_MODEL"
      }
    }.freeze

    class << self
      def call
        new.call
      end
    end

    def initialize(
      primary_provider: Ai::ProviderSelector.primary,
      fallback_provider: Ai::ProviderSelector.fallback
    )
      @primary_provider = primary_provider
      @fallback_provider = fallback_provider
    end

    def call
      operation_enabled? &&
        env_enabled? &&
        provider_configured?(primary_provider) &&
        fallback_provider_configured?
    rescue StandardError => e
      Rails.logger.warn(
        "[AI::AvailabilityChecker] unavailable class=#{e.class}"
      )
      false
    end

    private

    attr_reader :primary_provider, :fallback_provider

    def operation_enabled?
      SystemSettings.enabled?(OPERATION_SETTING_KEY)
    rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
      false
    end

    def env_enabled?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch(OPERATION_ENV_KEY, "true"))
    end

    def fallback_provider_configured?
      return true if fallback_provider.blank?

      provider_configured?(fallback_provider)
    end

    def provider_configured?(provider)
      normalized_provider = provider.to_s.strip.downcase.presence
      config = PROVIDER_CONFIG[normalized_provider]
      return false if config.blank?

      required_env_present?(config[:api_key_env]) &&
        required_env_present?(config[:model_env]) &&
        provider_implemented?(normalized_provider)
    end

    def required_env_present?(key)
      ENV[key].to_s.strip.present?
    end

    def provider_implemented?(provider)
      Ai::ProviderRegistry.implemented?(provider)
    end
  end
end
