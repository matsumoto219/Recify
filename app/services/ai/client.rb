module Ai
  class Client
    def initialize(
      primary_provider: ProviderSelector.primary,
      fallback_provider: ProviderSelector.fallback,
      runtime_config: nil
    )
      @primary_provider = primary_provider
      @fallback_provider = fallback_provider
      @runtime_config = runtime_config || ExternalServices.runtime_config_snapshot.ai
    end

    def call(input, before_provider_call: nil)
      deadline = monotonic_now + runtime_config.max_elapsed_seconds
      decorate_success_result(
        run_primary(input, before_provider_call: before_provider_call, deadline: deadline),
        fallback_used: false,
        fallback_provider: fallback_provider,
        fallback_reason: nil,
        final_provider: primary_provider
      )
    rescue Ai::Errors::ProviderError => primary_error
      fallback_decision = fallback_decision_for(primary_error)
      return failure_result(primary_error, nil) if fallback_decision.fail? && fallback_decision.fallbackable?

      raise primary_error unless fallback_decision.fallback?

      run_fallback(input, primary_error, fallback_decision, before_provider_call: before_provider_call, deadline: deadline)
    end

    private

    attr_reader :primary_provider, :fallback_provider, :runtime_config

    def run_primary(input, before_provider_call:, deadline:)
      provider_executor(primary_provider, before_provider_call: before_provider_call, deadline: deadline).call(input)
    rescue Ai::Errors::TimeoutError => error
      Rails.logger.error("[AI] primary_timeout class=#{error.class}")
      raise Ai::Errors::ProviderError.new(
        message: error.message,
        error_code: "ai_primary_failed",
        provider: primary_provider,
        cause: error,
        **provider_error_attributes(error)
      )
    rescue Ai::Errors::ProviderError => error
      Rails.logger.error(
        "[AI] primary_provider_error class=#{error.class} code=#{error.error_code.presence || 'unknown'}"
      )
      raise error if error.error_code.present?

      raise Ai::Errors::ProviderError.new(
        message: error.message,
        error_code: "ai_primary_failed",
        provider: primary_provider,
        cause: error,
        **provider_error_attributes(error)
      )
    end

    def run_fallback(input, primary_error, fallback_decision, before_provider_call:, deadline:)
      Rails.logger.warn("[AI] fallback triggered: primary=#{primary_provider}")

      result = provider_executor(fallback_provider, before_provider_call: before_provider_call, deadline: deadline).call(input)

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
    rescue Usage::LimitExceeded
      raise
    rescue StandardError => fallback_error
      failure_result(primary_error, build_fallback_error(fallback_error))
    end

    def provider_client(provider_name)
      ProviderRegistry.fetch(provider_name, runtime_config: runtime_config)
    end

    def provider_executor(provider_name, before_provider_call:, deadline:)
      Ai::ProviderExecutor.new(
        provider_client: provider_client(provider_name),
        provider_name: provider_name,
        before_provider_call: before_provider_call,
        deadline: deadline
      )
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
        **provider_error_attributes(error)
      )
    end

    def failure_result(primary_error, fallback_error)
      final_error = final_error(primary_error, fallback_error)

      ResultTemplate.error(
        error_code: final_error_code(primary_error, fallback_error),
        meta: {
          primary_provider: primary_provider,
          fallback_provider: fallback_provider,
          fallback_used: fallback_error.present?,
          primary_error_code: primary_error&.error_code,
          primary_error_message: safe_error_message(primary_error),
          primary_error_detail: provider_error_detail(primary_error, fallback_phase: false),
          fallback_error_code: fallback_error&.error_code,
          fallback_error_message: safe_error_message(fallback_error),
          fallback_error_detail: provider_error_detail(fallback_error, fallback_phase: true),
          final_provider: provider_name(final_error&.provider || fallback_error&.provider || primary_error&.provider || primary_provider),
          final_error_detail: provider_error_detail(final_error, fallback_phase: fallback_error.present?),
          metrics: failure_metrics(primary_error, fallback_error)
        }.compact
      )
    end

    def final_error(primary_error, fallback_error)
      fallback_error || primary_error
    end

    def provider_name(value)
      value.to_s.presence if value.present?
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

    def provider_error_attributes(error)
      return { metrics: nil } unless error.respond_to?(:metrics)

      {
        retry_after: error.respond_to?(:retry_after) ? error.retry_after : nil,
        provider_status: error.respond_to?(:provider_status) ? error.provider_status : nil,
        provider_error_code: error.respond_to?(:provider_error_code) ? error.provider_error_code : nil,
        provider_error_type: error.respond_to?(:provider_error_type) ? error.provider_error_type : nil,
        provider_message: error.respond_to?(:provider_message) ? error.provider_message : nil,
        request_id: error.respond_to?(:request_id) ? error.request_id : nil,
        quota_exceeded: error.respond_to?(:quota_exceeded) ? error.quota_exceeded : nil,
        rate_limited: error.respond_to?(:rate_limited) ? error.rate_limited : nil,
        auth_error: error.respond_to?(:auth_error) ? error.auth_error : nil,
        phase: error.respond_to?(:phase) ? error.phase : nil,
        metrics: error.metrics
      }.compact
    end

    def provider_error_detail(error, fallback_phase:)
      return unless error.respond_to?(:metrics)

      metrics = error.metrics || {}
      ExternalServices.error_detail(
        service: :ai,
        provider: error.provider || metrics[:provider] || (fallback_phase ? fallback_provider : primary_provider),
        phase: error.phase || metrics[:phase] || (fallback_phase ? :fallback : :ai_request),
        http_status: error.provider_status || metrics[:provider_status],
        provider_error_code: error.provider_error_code || metrics[:provider_error_code],
        provider_error_type: error.provider_error_type || metrics[:provider_error_type],
        provider_message: error.provider_message || metrics[:provider_message],
        request_id: error.request_id || metrics[:request_id],
        retry_after: error.retry_after || metrics[:retry_after],
        model: metrics[:model],
        rate_limited: error.rate_limited || metrics[:rate_limited],
        quota_exceeded: error.quota_exceeded || metrics[:quota_exceeded],
        auth_error: error.auth_error || metrics[:auth_error]
      ).presence
    end

    def safe_error_message(error)
      return unless error

      detail = provider_error_detail(error, fallback_phase: false)
      return detail[:provider_message_safe] if detail&.dig(:provider_message_safe).present?
      return "timeout" if error.is_a?(Ai::Errors::TimeoutError) || error.error_code.to_s.match?(/timeout/)
      return "rate limit" if error.respond_to?(:rate_limited) && error.rate_limited == true
      return "quota exceeded" if error.respond_to?(:quota_exceeded) && error.quota_exceeded == true
      return "auth error" if error.respond_to?(:auth_error) && error.auth_error == true

      error.error_code.presence || error.class.name
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
