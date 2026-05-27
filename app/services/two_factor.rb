module TwoFactor
  Error = Class.new(StandardError)
  VerificationError = Class.new(Error)

  class << self
    def generate_totp_secret
      Totp.generate_secret
    end

    def totp_provisioning_uri(user:, secret:)
      Totp.provisioning_uri(user: user, secret: secret)
    end

    def totp_qr_svg(provisioning_uri:)
      Totp.qr_svg(provisioning_uri: provisioning_uri)
    end

    def verify_totp_setup(user:, code:)
      Totp.verify_setup(user: user, code: code)
    end

    def verify_totp(user:, code:)
      Totp.verify(user: user, code: code)
    end

    def generate_recovery_codes_for(user:)
      RecoveryCodes.generate_for(user: user)
    end

    def regenerate_recovery_codes_for(user:)
      RecoveryCodes.regenerate_for(user: user)
    end

    def verify_recovery_code(user:, code:)
      RecoveryCodes.verify(user: user, code: code)
    end

    def recovery_code_digest(code)
      RecoveryCodes.digest(code)
    end
  end
end
