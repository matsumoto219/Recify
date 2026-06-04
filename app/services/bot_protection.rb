module BotProtection
  Result = Struct.new(:success, :error_code, keyword_init: true) do
    def success?
      success == true
    end

    def failed?
      !success?
    end
  end

  class << self
    def turnstile_enabled?
      truthy_env?(ENV["TURNSTILE_ENABLED"])
    end

    def turnstile_site_key
      ENV["TURNSTILE_SITE_KEY"].to_s.strip
    end

    def verify_turnstile(token:, remote_ip:)
      return success_result unless turnstile_enabled?
      return failure_result("turnstile_not_configured") unless turnstile_configured?

      TurnstileVerifier.call(token: token, remote_ip: remote_ip)
    end

    def success_result
      Result.new(success: true, error_code: nil)
    end

    def failure_result(error_code)
      Result.new(success: false, error_code: error_code.to_s)
    end

    private

    def turnstile_configured?
      turnstile_site_key.present? && ENV["TURNSTILE_SECRET_KEY"].to_s.strip.present?
    end

    def truthy_env?(value)
      ActiveModel::Type::Boolean.new.cast(value) == true
    end
  end
end
