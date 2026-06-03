require "time"

module Ai
  class BackoffPolicy
    def initialize(base_delay:, max_delay:, jitter: nil)
      @base_delay = base_delay.to_f
      @max_delay = max_delay.to_f
      @jitter = jitter || -> { rand * @base_delay }
    end

    def delay_for(attempt:, retry_after: nil)
      parsed_retry_after = retry_after_delay(retry_after)
      return cap_delay(parsed_retry_after) if parsed_retry_after

      cap_delay(exponential_delay(attempt) + jitter_delay)
    end

    def parse_retry_after(value, now: Time.current)
      raw_value = value.to_s.strip
      return if raw_value.blank?

      if raw_value.match?(/\A\d+(?:\.\d+)?\z/)
        return cap_delay(raw_value.to_f)
      end

      delay = Time.httpdate(raw_value) - now
      return if delay.negative?

      cap_delay(delay)
    rescue ArgumentError
      nil
    end

    private

    attr_reader :base_delay, :max_delay, :jitter

    def retry_after_delay(value)
      return if value.nil?

      cap_delay(value.to_f)
    end

    def exponential_delay(attempt)
      base_delay * (2**(attempt.to_i - 1))
    end

    def jitter_delay
      jitter.call.to_f
    end

    def cap_delay(delay)
      [ delay.to_f, max_delay ].min
    end
  end
end
