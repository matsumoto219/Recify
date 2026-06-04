class GuestSessionsController < ApplicationController
  before_action :verify_turnstile!, only: :create

  def create
    user = User.guest!
    sign_in user
    redirect_to receipts_path, notice: t("flash.guest_sessions.create.success")
  rescue StandardError => e
    Rails.logger.error("[GuestSessionsController] guest_sign_in_failed: #{e.class} #{e.message}")
    redirect_to new_user_session_path, alert: t("flash.guest_sessions.create.failure")
  end

  private

  def verify_turnstile!
    result = BotProtection.verify_turnstile(
      token: params["cf-turnstile-response"],
      remote_ip: request.remote_ip
    )

    return if result.success?

    redirect_to new_user_session_path, alert: t("flash.bot_protection.verification_failed")
  end
end
