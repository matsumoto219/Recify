require "timeout"

module Ai
  class ProviderExecutor
    DEFAULT_RETRY_POLICY = Ai::RetryPolicy.new(
      max_retries: 0,
      backoff_policy: Ai::BackoffPolicy.new(base_delay: 0.0, max_delay: 0.0, jitter: -> { 0.0 })
    )

    def initialize(provider_client:, provider_name: nil, retry_policy: nil, before_provider_call: nil, deadline: nil)
      @provider_client = provider_client
      @provider_name = provider_name
      @retry_policy = retry_policy
      @before_provider_call = before_provider_call
      @deadline = deadline
    end

    def call(input)
      start_metrics!
      attempts = 0

      begin
        ensure_elapsed_budget!
        attempts += 1
        result = ensure_provider_result!(call_provider_with_budget(input))
        ensure_elapsed_budget!
        build_result(result)
      rescue Ai::Errors::ProviderError => error
        enriched_error = build_error(error)
        raise enriched_error unless retry?(enriched_error, attempts)

        delay = current_retry_policy.delay_for(attempt: attempts, error: enriched_error)
        ensure_retry_delay_within_budget!(delay)
        track_retry!(error: enriched_error, delay: delay)
        sleep(delay)
        retry
      end
    ensure
      clear_metrics!
    end

    private

    attr_reader :provider_client, :provider_name, :retry_policy, :before_provider_call, :deadline

    def call_provider(input)
      return provider_client.call(input, before_provider_call: before_provider_call) if before_provider_call

      provider_client.call(input)
    end

    def call_provider_with_budget(input)
      return call_provider(input) unless deadline

      remaining = remaining_elapsed_seconds
      raise_elapsed_timeout! unless remaining.positive?

      Timeout.timeout(remaining) { call_provider(input) }
    rescue Timeout::Error => error
      raise_elapsed_timeout!(cause: error)
    end

    def build_result(result)
      metrics = Ai::ProviderMetrics.merge(current_metrics, result.metrics)
      metrics = Ai::ProviderMetrics.merge(metrics, elapsed_ms: elapsed_ms)
      payload = result.payload
      payload[:meta] ||= {}
      payload[:meta][:metrics] = metrics

      Ai::ProviderResult.new(
        provider: result.provider || provider_name,
        model: result.model,
        payload: payload,
        metrics: metrics,
        response_id: result.response_id
      )
    end

    def build_error(error)
      metrics = Ai::ProviderMetrics.merge(current_metrics, error.metrics)
      metrics = Ai::ProviderMetrics.merge(metrics, elapsed_ms: elapsed_ms)
      metrics = Ai::ProviderMetrics.merge(metrics, rate_limited: true) if error.is_a?(Ai::Errors::RateLimitError)

      rebuild_error(error, metrics: metrics)
    end

    def rebuild_error(error, metrics:)
      if error.is_a?(Ai::Errors::TimeoutError)
        return Ai::Errors::TimeoutError.new(
          message: error.message,
          provider: error.provider || provider_name,
          category: error.category,
          retryable: error.retryable?,
          fallbackable: error.fallbackable?,
          cause: error.cause,
          retry_after: error.retry_after,
          provider_status: error.provider_status,
          **provider_error_attributes(error),
          metrics: metrics
        )
      end

      error.class.new(
        message: error.message,
        error_code: error.error_code,
        provider: error.provider || provider_name,
        category: error.category,
        retryable: error.retryable?,
        fallbackable: error.fallbackable?,
        cause: error.cause,
        retry_after: error.retry_after,
        provider_status: error.provider_status,
        **provider_error_attributes(error),
        metrics: metrics
      )
    end

    def provider_error_attributes(error)
      {
        provider_error_code: error.respond_to?(:provider_error_code) ? error.provider_error_code : nil,
        provider_error_type: error.respond_to?(:provider_error_type) ? error.provider_error_type : nil,
        provider_message: error.respond_to?(:provider_message) ? error.provider_message : nil,
        request_id: error.respond_to?(:request_id) ? error.request_id : nil,
        quota_exceeded: error.respond_to?(:quota_exceeded) ? error.quota_exceeded : nil,
        rate_limited: error.respond_to?(:rate_limited) ? error.rate_limited : nil,
        auth_error: error.respond_to?(:auth_error) ? error.auth_error : nil,
        phase: error.respond_to?(:phase) ? error.phase : nil
      }
    end

    def retry?(error, attempts)
      return false unless current_retry_policy.retryable?(error)

      attempts <= current_retry_policy.max_retries
    end

    def ensure_elapsed_budget!
      return unless deadline
      return if remaining_elapsed_seconds.positive?

      raise_elapsed_timeout!
    end

    def ensure_retry_delay_within_budget!(delay)
      return unless deadline
      return if delay.to_f < remaining_elapsed_seconds

      raise_elapsed_timeout!
    end

    def remaining_elapsed_seconds
      deadline.to_f - monotonic_now
    end

    def raise_elapsed_timeout!(cause: nil)
      raise Ai::Errors::TimeoutError.new(
        message: "AI maximum elapsed time exceeded",
        provider: provider_name,
        retryable: false,
        fallbackable: true,
        cause: cause,
        phase: "ai_request",
        metrics: Ai::ProviderMetrics.merge(current_metrics, elapsed_ms: elapsed_ms)
      )
    end

    def track_retry!(error:, delay:)
      retry_after = current_retry_policy.retry_after_for(error)
      @current_metrics = Ai::ProviderMetrics.merge(
        current_metrics,
        retry_count: current_metrics.fetch(:retry_count, 0).to_i + 1,
        retry_after_used: current_metrics[:retry_after_used] == true || retry_after.present?,
        total_retry_sleep_ms: current_metrics.fetch(:total_retry_sleep_ms, 0).to_i + (delay.to_f * 1000).round,
        rate_limited: current_metrics[:rate_limited] == true || error.is_a?(Ai::Errors::RateLimitError)
      )
    end

    def ensure_provider_result!(result)
      return result if result.is_a?(Ai::ProviderResult)

      raise Ai::Errors::ProviderError.new(
        message: "AI provider returned invalid result",
        error_code: "ai_invalid_response",
        provider: provider_name,
        category: :invalid_response,
        retryable: false,
        fallbackable: false
      )
    end

    def current_retry_policy
      retry_policy || provider_retry_policy || DEFAULT_RETRY_POLICY
    end

    def provider_retry_policy
      return unless provider_client.respond_to?(:retry_policy)

      provider_client.retry_policy
    end

    def start_metrics!
      @started_at = monotonic_now
      @current_metrics = Ai::ProviderMetrics.build(
        provider: provider_name,
        retry_count: 0,
        retry_after_used: false,
        total_retry_sleep_ms: 0,
        rate_limited: false
      )
    end

    def clear_metrics!
      @started_at = nil
      @current_metrics = nil
    end

    def current_metrics
      @current_metrics || {}
    end

    def elapsed_ms
      return unless @started_at

      ((monotonic_now - @started_at) * 1000).round
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
