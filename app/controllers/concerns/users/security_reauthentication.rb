module Users::SecurityReauthentication
  extend ActiveSupport::Concern

  SESSION_KEY = :security_reauthentication
  WINDOW_SETTING_KEY = "security.user_reauth_window_minutes".freeze
  DEFAULT_WINDOW_DURATION = 5.minutes

  private

  def record_security_reauthentication!(user:, method:)
    authenticated_at = Time.current
    session[SESSION_KEY] = {
      "user_id" => user.id,
      "session_version" => user.session_version.to_i,
      "method" => method.to_s,
      "authenticated_at" => authenticated_at.iso8601,
      "expires_at" => (authenticated_at + security_reauthentication_window_duration).iso8601
    }
  end

  def clear_security_reauthentication!
    session.delete(SESSION_KEY)
  end

  def security_reauthentication_fresh?(user = current_user)
    context = security_reauthentication_context
    authenticated_at = Time.zone.parse(context["authenticated_at"].to_s)
    return false unless authenticated_at

    issued_expires_at = security_reauthentication_issued_expires_at(context, authenticated_at)
    current_expires_at = authenticated_at + security_reauthentication_window_duration
    effective_expires_at = [ issued_expires_at, current_expires_at ].min

    user.present? &&
      context["user_id"].to_i == user.id &&
      context["session_version"].to_i == user.session_version.to_i &&
      authenticated_at <= Time.current &&
      effective_expires_at >= Time.current
  rescue ArgumentError, TypeError
    false
  end

  def security_reauthentication_issued_expires_at(context, authenticated_at)
    value = context["expires_at"].presence
    return authenticated_at + DEFAULT_WINDOW_DURATION unless value

    Time.zone.parse(value.to_s)
  end

  def security_reauthentication_window_duration
    SystemSettings.limit_for(WINDOW_SETTING_KEY).minutes
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
    DEFAULT_WINDOW_DURATION
  end

  def security_reauthentication_context
    session[SESSION_KEY].to_h.stringify_keys
  end

  def require_fresh_security_reauthentication!
    return if security_reauthentication_fresh?

    clear_security_reauthentication!
    clear_security_management_capabilities!
    reauthentication_url = new_settings_security_reauthentication_path(
      return_to: security_reauthentication_return_to
    )

    respond_to do |format|
      format.html do
        redirect_to reauthentication_url,
                    alert: t("settings.security.reauthentication.messages.required"),
                    status: :see_other
      end
      format.json do
        render json: {
          ok: false,
          error: t("settings.security.reauthentication.messages.required"),
          reauthentication_url: reauthentication_url
        }, status: :precondition_required
      end
    end
  end

  def security_reauthentication_return_to
    settings_security_path
  end

  def clear_security_management_capabilities!
    session.delete(Users::PasskeysController::REGISTRATION_CHALLENGE_SESSION_KEY)
    session.delete(Users::TwoFactor::TotpSettingsController::SETUP_SESSION_KEY)
  end
end
