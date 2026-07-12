class Users::SecurityReauthenticationsController < ApplicationController
  RETURN_TO_SESSION_KEY = :security_reauthentication_return_to

  rate_limit to: 5,
             within: 5.minutes,
             by: :security_reauthentication_rate_limit_key,
             with: :rate_limit_exceeded,
             store: ApplicationController::RateLimitStore,
             name: "security_reauthentication/user_ip",
             only: :create

  before_action :authenticate_user!
  before_action :ensure_security_management_allowed!
  before_action :set_no_store_headers

  def new
    session[RETURN_TO_SESSION_KEY] = safe_return_to(params[:return_to]) if params[:return_to].present?
  end

  def create
    if current_user.valid_password?(params[:password].to_s)
      record_security_reauthentication!(user: current_user, method: "password")
      redirect_to consume_return_to,
                  notice: t("settings.security.reauthentication.messages.succeeded"),
                  status: :see_other
    else
      clear_security_reauthentication!
      flash.now[:alert] = t("settings.security.reauthentication.messages.failed")
      render :new, status: :unprocessable_content
    end
  end

  private

  def ensure_security_management_allowed!
    return if current_user.confirmed? && !current_user.guest?

    redirect_to settings_security_path,
                alert: t("settings.security.reauthentication.messages.unavailable"),
                status: :see_other
  end

  def safe_return_to(value)
    value = value.to_s
    allowed_paths = [
      settings_security_path,
      settings_security_path(anchor: "passkeys"),
      settings_security_path(anchor: "two-factor"),
      new_settings_security_totp_path
    ]

    allowed_paths.include?(value) ? value : settings_security_path
  end

  def consume_return_to
    safe_return_to(session.delete(RETURN_TO_SESSION_KEY))
  end

  def security_reauthentication_rate_limit_key
    [ "user", current_user&.id || "unknown", "ip", request.remote_ip ].join(":")
  end

  def set_no_store_headers
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
  end
end
