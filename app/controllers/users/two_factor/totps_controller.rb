# frozen_string_literal: true

class Users::TwoFactor::TotpsController < ApplicationController
  include Users::TwoFactor::PendingSecondFactor

  rate_limit to: 5,
             within: 5.minutes,
             by: :rate_limit_pending_second_factor_user_ip_key,
             with: :rate_limit_exceeded,
             store: ApplicationController::RateLimitStore,
             name: "totp_step_up/create/pending_user_ip",
             only: :create

  before_action -> { require_pending_second_factor!(method: "totp") }, only: %i[new create]

  def new
  end

  def create
    TwoFactor.verify_totp(user: @pending_user, code: params[:code])
    complete_pending_second_factor!(
      user: @pending_user,
      sign_in_method: "password_totp_step_up"
    )

    redirect_to after_sign_in_path_for(@pending_user), notice: t("auth.two_factor.totp.messages.success"), status: :see_other
  rescue TwoFactor::VerificationError
    flash.now[:alert] = t("auth.two_factor.totp.messages.failure")
    render :new, status: :unprocessable_content
  end

  private

  def pending_user_still_allowed?(user)
    super && user.totp_credential&.confirmed?
  end
end
