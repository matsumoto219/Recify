class Users::TwoFactor::RecoveryCodesController < ApplicationController
  before_action :authenticate_user!
  before_action :ensure_two_factor_management_allowed!
  before_action :ensure_totp_enabled!
  before_action :set_no_store_headers

  def regenerate
    @recovery_codes = TwoFactor.regenerate_recovery_codes_for(user: current_user)
    render :show, status: :created
  end

  private

  def ensure_two_factor_management_allowed!
    return if current_user.confirmed? && !current_user.guest?

    redirect_to settings_security_path, alert: t("settings.security.auth.two_factor.messages.unavailable")
  end

  def ensure_totp_enabled!
    return if current_user.totp_credential&.confirmed?

    redirect_to settings_security_path(anchor: "two-factor"), alert: t("settings.security.auth.two_factor.messages.not_enabled")
  end

  def set_no_store_headers
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
  end
end
