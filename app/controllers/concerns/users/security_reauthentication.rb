module Users::SecurityReauthentication
  extend ActiveSupport::Concern

  SESSION_KEY = :security_reauthentication
  TTL = 5.minutes

  private

  def record_security_reauthentication!(user:, method:)
    session[SESSION_KEY] = {
      "user_id" => user.id,
      "session_version" => user.session_version.to_i,
      "method" => method.to_s,
      "authenticated_at" => Time.current.iso8601
    }
  end

  def clear_security_reauthentication!
    session.delete(SESSION_KEY)
  end

  def security_reauthentication_fresh?(user = current_user)
    context = security_reauthentication_context
    authenticated_at = Time.zone.parse(context["authenticated_at"].to_s)

    user.present? &&
      context["user_id"].to_i == user.id &&
      context["session_version"].to_i == user.session_version.to_i &&
      authenticated_at.present? &&
      authenticated_at <= Time.current &&
      authenticated_at >= TTL.ago
  rescue ArgumentError, TypeError
    false
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
