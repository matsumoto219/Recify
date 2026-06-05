module Settings
  class SecurityPresenter
    attr_reader :totp_credential, :recovery_codes_status, :passkeys

    def initialize(user:)
      @user = user
      @totp_credential = user.totp_credential
      @totp_enabled = @totp_credential&.confirmed?
      @recovery_codes_status = @totp_enabled ? TwoFactor.recovery_codes_status(user: user) : nil
      @passkeys = user.passkeys.order(created_at: :desc).to_a
    end

    def totp_enabled?
      @totp_enabled == true
    end

    def recovery_status_classes
      case recovery_codes_status&.status
      when :empty
        "token-state-error-soft token-text-error"
      when :low, :missing
        "token-state-warning-soft token-text-warning"
      else
        "token-bg-card-subtle token-text-muted"
      end
    end

    def passkeys?
      passkeys.any?
    end

    def passkey_label(passkey)
      passkey.label.presence || I18n.t("settings.security.auth.passkey.default_label")
    end

    def passkey_count
      passkeys.size
    end

    def passkey_limit
      Passkeys.registration_limit
    end

    def passkey_remaining_slots
      Passkeys.remaining_slots_for(@user)
    end

    def passkey_limit_reached?
      Passkeys.registration_limit_reached?(@user)
    end
  end
end
