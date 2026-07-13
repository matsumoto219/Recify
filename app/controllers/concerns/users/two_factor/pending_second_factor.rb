# frozen_string_literal: true

module Users::TwoFactor::PendingSecondFactor
  extend ActiveSupport::Concern

  included do
    helper_method :pending_second_factor_allowed_methods, :pending_second_factor_fallback_methods_for
  end

  private

  def require_pending_second_factor!(method:)
    @pending_user = pending_second_factor_user(method: method)
    return if @pending_user.present?

    clear_pending_second_factor

    respond_to do |format|
      format.html do
        redirect_to new_user_session_path,
                    flash: { warning: t("auth.two_factor.messages.expired") }
      end
      format.json { render json: { ok: false, error: t("auth.two_factor.messages.expired") }, status: :unauthorized }
    end
  end

  def pending_second_factor_user(method: nil)
    pending = pending_second_factor_session
    return if pending.blank?

    allowed_methods = pending["allowed_methods"].to_a
    return if method.present? && !allowed_methods.include?(method)

    issued_at = Time.zone.parse(pending["issued_at"].to_s)
    return if issued_at.blank? || issued_at < Users::SessionsController::PENDING_SECOND_FACTOR_TTL.ago

    user = User.find_by(id: pending["user_id"])
    return if user.blank?
    return unless pending_user_still_allowed?(user)

    user
  rescue ArgumentError, TypeError
    nil
  end

  def pending_user_still_allowed?(user)
    user.active_for_authentication? && !user.guest? && Maintenance.login_allowed_for?(user)
  end

  def pending_second_factor_session
    session[Users::SessionsController::PENDING_SECOND_FACTOR_SESSION_KEY].to_h
  end

  def pending_second_factor_allowed_methods
    pending_second_factor_session["allowed_methods"].to_a
  end

  def pending_second_factor_fallback_methods_for(method)
    pending_second_factor_allowed_methods - [ method.to_s ]
  end

  def rate_limit_pending_second_factor_user_ip_key
    pending_user_id = pending_second_factor_session["user_id"].presence || "unknown"

    [ "pending-user", pending_user_id, "ip", request.remote_ip ].join(":")
  end

  def complete_pending_second_factor!(user:, sign_in_method:)
    remember_me = pending_second_factor_session["remember_me"]
    clear_pending_second_factor
    user.remember_me = remember_me
    sign_in(:user, user)
    store_user_session_version(user)
    record_security_reauthentication!(user: user, method: sign_in_method)
    UserSessions.record_sign_in(user: user, request: request, session: session, method: sign_in_method)
  end

  def clear_pending_second_factor
    session.delete(Users::SessionsController::PENDING_SECOND_FACTOR_SESSION_KEY)
    clear_pending_second_factor_challenges
  end

  def clear_pending_second_factor_challenges
    session.delete(:passkey_step_up_challenge)
  end
end
