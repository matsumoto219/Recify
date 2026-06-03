module Ai
  class FallbackDecision
    attr_reader :action,
                :reason,
                :provider,
                :fallback_provider,
                :retry_after,
                :max_delay_exceeded,
                :fallbackable

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(error:, provider:, fallback_provider:, max_retry_after: nil)
      @error = error
      @provider = provider
      @fallback_provider = fallback_provider
      @max_retry_after = max_retry_after
    end

    def call
      fallbackable = fallbackable_error?
      return build(:fallback, reason: error_reason, fallbackable: fallbackable) if fallback_available? && fallbackable

      build(:fail, reason: error_reason, fallbackable: fallbackable)
    end

    def fallback?
      action == :fallback
    end

    def retry?
      action == :retry
    end

    def fail?
      action == :fail
    end

    def fallbackable?
      fallbackable
    end

    private

    attr_reader :error, :max_retry_after

    def build(action, reason:, fallbackable:)
      self.class.new_result(
        action: action,
        reason: reason,
        provider: provider,
        fallback_provider: fallback_provider,
        retry_after: error_retry_after,
        max_delay_exceeded: max_delay_exceeded?,
        fallbackable: fallbackable
      )
    end

    def self.new_result(action:, reason:, provider:, fallback_provider:, retry_after:, max_delay_exceeded:, fallbackable:)
      allocate.tap do |decision|
        decision.instance_variable_set(:@action, action)
        decision.instance_variable_set(:@reason, reason)
        decision.instance_variable_set(:@provider, provider)
        decision.instance_variable_set(:@fallback_provider, fallback_provider)
        decision.instance_variable_set(:@retry_after, retry_after)
        decision.instance_variable_set(:@max_delay_exceeded, max_delay_exceeded)
        decision.instance_variable_set(:@fallbackable, fallbackable)
      end
    end

    def fallback_available?
      fallback_provider.present? && fallback_provider != provider
    end

    def fallbackable_error?
      return true if error.respond_to?(:fallbackable?) && error.fallbackable?

      case error
      when Ai::Errors::TimeoutError, Ai::Errors::RateLimitError
        true
      when Ai::Errors::AuthError, Ai::Errors::InvalidResponseError
        false
      when Ai::Errors::ProviderError
        %w[
          ai_primary_failed
          ai_api_error
        ].include?(error.error_code)
      else
        false
      end
    end

    def error_reason
      error.respond_to?(:error_code) ? error.error_code : error.class.name
    end

    def error_retry_after
      return unless error.respond_to?(:retry_after)

      error.retry_after
    end

    def max_delay_exceeded?
      return false if max_retry_after.nil? || error_retry_after.nil?

      error_retry_after.to_f > max_retry_after.to_f
    end
  end
end
