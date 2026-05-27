module TwoFactor
  Error = Class.new(StandardError)
  VerificationError = Class.new(Error)
  SetupMaterial = Struct.new(:secret, :provisioning_uri, :qr_svg, keyword_init: true)
  SetupConfirmation = Struct.new(:credential, :recovery_codes, keyword_init: true)
  RecoveryCodesStatus = Struct.new(:enabled, :unused_count, :status, keyword_init: true)

  class << self
    def prepare_totp_setup(user:)
      Totp.prepare_setup(user: user)
    end

    def generate_totp_secret
      Totp.generate_secret
    end

    def totp_provisioning_uri(user:, secret:)
      Totp.provisioning_uri(user: user, secret: secret)
    end

    def totp_qr_svg(provisioning_uri:)
      Totp.qr_svg(provisioning_uri: provisioning_uri)
    end

    def confirm_totp_setup(user:, secret:, code:)
      Totp.confirm_setup(user: user, secret: secret, code: code)
    end

    def verify_totp_setup(user:, code:, secret: nil)
      Totp.verify_setup(user: user, code: code, secret: secret)
    end

    def verify_totp(user:, code:)
      Totp.verify(user: user, code: code)
    end

    def disable_totp_for(user:)
      Totp.disable_for(user: user)
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

    def recovery_codes_status(user:)
      RecoveryCodes.status(user: user)
    end

    def recovery_code_digest(code)
      RecoveryCodes.digest(code)
    end
  end
end
