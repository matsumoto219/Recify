class Users::TwoFactor::RecoveryCodesController < ApplicationController
  include Users::TwoFactor::PendingSecondFactor

  rate_limit to: 5,
             within: 10.minutes,
             by: :rate_limit_pending_second_factor_user_ip_key,
             with: :rate_limit_exceeded,
             store: ApplicationController::RateLimitStore,
             name: "recovery_code_step_up/create/pending_user_ip",
             only: :create

  before_action :authenticate_user!, only: :regenerate
  before_action :ensure_two_factor_management_allowed!, only: :regenerate
  before_action :ensure_totp_enabled!, only: :regenerate
  before_action :require_fresh_security_reauthentication!, only: :regenerate
  before_action -> { require_pending_second_factor!(method: "recovery_code") }, only: %i[new create]
  before_action :set_no_store_headers

  def new
  end

  def create
    TwoFactor.verify_recovery_code(user: @pending_user, code: params[:code])
    complete_pending_second_factor!(
      user: @pending_user,
      sign_in_method: "password_recovery_code_step_up"
    )

    redirect_to after_sign_in_path_for(@pending_user), notice: t("auth.two_factor.recovery_code.messages.success"), status: :see_other
  rescue TwoFactor::VerificationError
    flash.now[:alert] = t("auth.two_factor.recovery_code.messages.failure")
    render :new, status: :unprocessable_content
  end

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

  def pending_user_still_allowed?(user)
    super && user.recovery_codes.where(used_at: nil).exists?
  end

  def set_no_store_headers
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
  end

  def security_reauthentication_return_to
    settings_security_path(anchor: "two-factor")
  end
end
