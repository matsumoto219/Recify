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
      decorate_success_result(
        run_primary(input),
        fallback_used: false,
        fallback_provider: fallback_provider,
        fallback_reason: nil,
        final_provider: primary_provider
      )
    rescue Ai::Errors::ProviderError => primary_error
      fallback_decision = fallback_decision_for(primary_error)
      return failure_result(primary_error, nil) if fallback_decision.fail? && fallback_decision.fallbackable?

      raise primary_error unless fallback_decision.fallback?

      run_fallback(input, primary_error, fallback_decision)
    end

    private

    attr_reader :primary_provider, :fallback_provider

    def run_primary(input)
      provider_executor(primary_provider).call(input)
    rescue Ai::Errors::TimeoutError => error
      Rails.logger.error("[AI] primary timeout: #{error.message}")
      raise Ai::Errors::ProviderError.new(
        message: error.message,
        error_code: "ai_primary_failed",
        provider: primary_provider,
        cause: error,
        metrics: error.metrics
      )
    rescue Ai::Errors::ProviderError => error
      Rails.logger.error("[AI] primary provider error: #{error.message}")
      raise error if error.error_code.present?

      raise Ai::Errors::ProviderError.new(
        message: error.message,
        error_code: "ai_primary_failed",
        provider: primary_provider,
        cause: error,
        metrics: error.metrics
      )
    end

    def run_fallback(input, primary_error, fallback_decision)
      Rails.logger.warn("[AI] fallback triggered: primary=#{primary_provider}")

      result = provider_executor(fallback_provider).call(input)

      decorate_success_result(
        result,
        fallback_used: true,
        fallback_provider: fallback_provider,
        fallback_reason: fallback_decision.reason,
        final_provider: fallback_provider
      )
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

    def provider_executor(provider_name)
      Ai::ProviderExecutor.new(
        provider_client: provider_client(provider_name),
        provider_name: provider_name
      )
    end

    def fallback_decision_for(error)
      Ai::FallbackDecision.call(
        error: error,
        provider: primary_provider,
        fallback_provider: fallback_provider
      )
    end

    def build_fallback_error(error)
      Ai::Errors::ProviderError.new(
        message: error.message,
        error_code: "ai_fallback_failed",
        provider: fallback_provider,
        cause: error,
        metrics: error.respond_to?(:metrics) ? error.metrics : nil
      )
    end

    def failure_result(primary_error, fallback_error)
      ResultTemplate.error(
        error_code: final_error_code(primary_error, fallback_error),
        meta: {
          primary_provider: primary_provider,
          fallback_provider: fallback_provider,
          fallback_used: fallback_error.present?,
          primary_error_code: primary_error&.error_code,
          primary_error_message: primary_error&.message,
          fallback_error_code: fallback_error&.error_code,
          fallback_error_message: fallback_error&.message,
          metrics: failure_metrics(primary_error, fallback_error)
        }.compact
      )
    end

    def final_error_code(primary_error, fallback_error)
      return fallback_error.error_code if fallback_error&.error_code.present?
      return primary_error.error_code if primary_error&.error_code.present?

      "ai_api_error"
    end

    def decorate_success_result(result, fallback_used:, fallback_provider:, fallback_reason:, final_provider:)
      result = ensure_provider_result!(result)
      payload = result.payload

      fallback_provider_name = fallback_provider.to_s.presence

      payload[:meta] ||= {}
      payload[:meta][:fallback_used] = fallback_used
      payload[:meta][:fallback_provider] = fallback_provider_name if fallback_provider_name.present?
      payload[:meta][:fallback_reason] = fallback_reason if fallback_reason.present?
      payload[:meta][:metrics] = Ai::ProviderMetrics.merge(
        result.metrics,
        fallback_used: fallback_used,
        fallback_provider: fallback_provider_name,
        fallback_reason: fallback_reason,
        final_provider: final_provider
      )
      payload
    end

    def failure_metrics(primary_error, fallback_error)
      metrics = Ai::ProviderMetrics.merge(primary_error&.metrics, fallback_error&.metrics || {})
      Ai::ProviderMetrics.merge(
        metrics,
        fallback_used: fallback_error.present?,
        fallback_provider: fallback_provider,
        fallback_reason: primary_error&.error_code,
        final_provider: fallback_error&.provider || primary_error&.provider || primary_provider
      )
    end

    def ensure_provider_result!(result)
      return result if result.is_a?(Ai::ProviderResult)

      raise Ai::Errors::ProviderError.new(
        message: "AI provider returned invalid result",
        error_code: "ai_invalid_response",
        provider: primary_provider,
        category: :invalid_response,
        retryable: false,
        fallbackable: false
      )
    end
  end
end
