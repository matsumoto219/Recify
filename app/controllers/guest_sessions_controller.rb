class GuestSessionsController < ApplicationController
  prepend_before_action :enforce_maintenance_restriction!, only: :create
  before_action :verify_turnstile!, only: :create

  def create
    user = User.guest!
    sign_in user
    redirect_to receipts_path, notice: t("flash.guest_sessions.create.success")
  rescue StandardError => e
    Rails.logger.warn("[GuestSessionsController] guest_session_create_failed error_class=#{e.class.name}")
    redirect_to new_user_session_path, alert: t("flash.guest_sessions.create.failure")
  end

  private

  def enforce_maintenance_restriction!
    return unless maintenance_login_restricted?

    redirect_to new_user_session_path, alert: maintenance_restriction_message
  end

  def verify_turnstile!
    result = BotProtection.verify_turnstile(
      token: params["cf-turnstile-response"],
      remote_ip: request.remote_ip
    )

    return if result.success?

    redirect_to new_user_session_path, alert: t("flash.bot_protection.verification_failed")
  end
end
