module Ai
  class Client
    def initialize(
      primary_provider: ProviderSelector.primary,
      fallback_provider: ProviderSelector.fallback
    )
      @primary_provider = primary_provider
      @fallback_provider = fallback_provider
    end

    def call(input)
      run_primary(input)
    rescue Ai::Errors::ProviderError => primary_error
      run_fallback(input, primary_error)
    end

    private

    attr_reader :primary_provider, :fallback_provider

    def run_primary(input)
      provider_client(primary_provider).call(input)
    rescue Ai::Errors::TimeoutError => error
      raise Ai::Errors::ProviderError.new(
        message: error.message,
        error_code: "ai_primary_failed",
        provider: primary_provider,
        cause: error
      )
    rescue Ai::Errors::ProviderError => error
      raise error if error.error_code.present?

      raise Ai::Errors::ProviderError.new(
        message: error.message,
        error_code: "ai_primary_failed",
        provider: primary_provider,
        cause: error
      )
    end

    def run_fallback(input, primary_error)
      return failure_result(primary_error, nil) unless fallback_available?

      provider_client(fallback_provider).call(input)
    rescue Ai::Errors::TimeoutError => fallback_error
      failure_result(primary_error, build_fallback_error(fallback_error))
    rescue Ai::Errors::ProviderError => fallback_error
      normalized_fallback_error = fallback_error.error_code.present? ? fallback_error : build_fallback_error(fallback_error)
      failure_result(primary_error, normalized_fallback_error)
    rescue StandardError => fallback_error
      failure_result(primary_error, build_fallback_error(fallback_error))
    end

    def provider_client(provider_name)
      ProviderRegistry.fetch(provider_name)
    end

    def fallback_available?
      fallback_provider.present? && fallback_provider != primary_provider
    end

    def build_fallback_error(error)
      Ai::Errors::ProviderError.new(
        message: error.message,
        error_code: "ai_fallback_failed",
        provider: fallback_provider,
        cause: error
      )
    end

    def failure_result(primary_error, fallback_error)
      ResultTemplate.error(
        error_code: final_error_code(primary_error, fallback_error),
        meta: {
          primary_provider: primary_provider,
          fallback_provider: fallback_provider,
          primary_error_code: primary_error&.error_code,
          primary_error_message: primary_error&.message,
          fallback_error_code: fallback_error&.error_code,
          fallback_error_message: fallback_error&.message
        }.compact
      )
    end

    def final_error_code(primary_error, fallback_error)
      return fallback_error.error_code if fallback_error&.error_code.present?
      return primary_error.error_code if primary_error&.error_code.present?

      "ai_api_error"
    end
  end
end
