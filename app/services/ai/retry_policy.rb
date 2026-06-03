require "net/http"

module Ai
  class RetryPolicy
    attr_reader :max_retries

    def initialize(max_retries:, backoff_policy:)
      @max_retries = max_retries.to_i
      @backoff_policy = backoff_policy
    end

    def retryable?(error)
      case error
      when Net::OpenTimeout, Net::ReadTimeout
        true
      when Ai::Errors::RateLimitError
        true
      when Ai::Errors::ProviderError
        error.retryable? || error.error_code == "ai_api_error"
      else
        false
      end
    end

    def delay_for(attempt:, error:)
      backoff_policy.delay_for(attempt: attempt, retry_after: retry_after_for(error))
    end

    def retry_after_for(error)
      return unless error.respond_to?(:retry_after)

      error.retry_after
    end

    private

    attr_reader :backoff_policy
  end
end
