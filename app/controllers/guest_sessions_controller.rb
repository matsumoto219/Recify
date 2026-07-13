class GuestSessionsController < ApplicationController
  prepend_before_action :enforce_maintenance_restriction!, only: :create
  before_action :redirect_authenticated_user!, only: :create
  before_action :verify_turnstile!, only: :create

  def create
    user = nil

    User.transaction do
      user = User.guest!
      sign_in user
      store_user_session_version(user)
      UserSessions.record_sign_in!(user: user, request: request, session: session, method: "guest")
    end

    redirect_to receipts_path, notice: t("flash.guest_sessions.create.success")
  rescue StandardError => e
    clear_failed_guest_session(user)
    Rails.logger.warn("[GuestSessionsController] guest_session_create_failed error_class=#{e.class.name}")
    redirect_to new_user_session_path, alert: t("flash.guest_sessions.create.failure")
  end

  private

  def enforce_maintenance_restriction!
    return unless maintenance_login_restricted?

    redirect_to new_user_session_path, alert: maintenance_restriction_message
  end

  def redirect_authenticated_user!
    return unless user_signed_in?

    redirect_to receipts_path, status: :see_other
  end

  def verify_turnstile!
    result = BotProtection.verify_turnstile(
      token: params["cf-turnstile-response"],
      remote_ip: request.remote_ip
    )

    return if result.success?

    redirect_to new_user_session_path, alert: t("flash.bot_protection.verification_failed")
  end

  def clear_failed_guest_session(user)
    UserSessions.record_sign_out(user: user, session: session)
    clear_user_session_version
    sign_out(:user) if user_signed_in?
  end
end
