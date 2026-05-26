# frozen_string_literal: true

class Users::TwoFactor::PasskeysController < ApplicationController
  PENDING_SECOND_FACTOR_SESSION_KEY = Users::SessionsController::PENDING_SECOND_FACTOR_SESSION_KEY
  PENDING_SECOND_FACTOR_TTL = Users::SessionsController::PENDING_SECOND_FACTOR_TTL
  STEP_UP_CHALLENGE_SESSION_KEY = :passkey_step_up_challenge
  STEP_UP_CHALLENGE_TTL = 5.minutes

  rate_limit to: 10,
             within: 5.minutes,
             by: :rate_limit_remote_ip_key,
             with: :rate_limit_exceeded,
             store: ApplicationController::RateLimitStore,
             name: "passkey_step_up/options/ip",
             only: :options

  rate_limit to: 10,
             within: 5.minutes,
             by: :rate_limit_remote_ip_key,
             with: :rate_limit_exceeded,
             store: ApplicationController::RateLimitStore,
             name: "passkey_step_up/create/ip",
             only: :create

  before_action :require_pending_second_factor!, only: %i[new options create]

  def new
  end

  def options
    options = Passkeys.step_up_options(user: @pending_user)
    session[STEP_UP_CHALLENGE_SESSION_KEY] = {
      "challenge" => options.challenge,
      "issued_at" => Time.current.iso8601
    }

    render json: { publicKey: options.as_json }
  end

  def create
    challenge = consume_step_up_challenge
    return render_step_up_error if challenge.blank?

    Passkeys.verify_step_up(
      user: @pending_user,
      credential: credential_params,
      challenge: challenge
    ) do |user|
      raise Passkeys::AuthenticationError, "step_up_not_allowed" unless pending_user_still_allowed?(user)
    end

    remember_me = pending_second_factor_session["remember_me"]
    clear_pending_second_factor
    @pending_user.remember_me = remember_me
    sign_in(:user, @pending_user)
    store_user_session_version(@pending_user)
    UserSessions.record_sign_in(user: @pending_user, request: request, session: session, method: "password_passkey_step_up")

    render json: {
      ok: true,
      redirect_url: after_sign_in_path_for(@pending_user)
    }
  rescue ActiveRecord::RecordNotFound,
         Passkeys::AuthenticationError,
         WebAuthn::Error,
         WebAuthn::VerificationError,
         KeyError,
         ActionController::ParameterMissing
    render_step_up_error
  end

  private

  def require_pending_second_factor!
    @pending_user = pending_second_factor_user
    return if @pending_user.present?

    clear_pending_second_factor

    respond_to do |format|
      format.html { redirect_to new_user_session_path, alert: t("auth.two_factor.passkey.messages.expired") }
      format.json { render json: { ok: false, error: t("auth.two_factor.passkey.messages.expired") }, status: :unauthorized }
    end
  end

  def pending_second_factor_user
    pending = pending_second_factor_session
    return if pending.blank?
    return unless pending["allowed_methods"].to_a.include?("passkey")

    issued_at = Time.zone.parse(pending["issued_at"].to_s)
    return if issued_at.blank? || issued_at < PENDING_SECOND_FACTOR_TTL.ago

    user = User.find_by(id: pending["user_id"])
    return if user.blank?
    return unless pending_user_still_allowed?(user)

    user
  rescue ArgumentError, TypeError
    nil
  end

  def pending_user_still_allowed?(user)
    user.active_for_authentication? && !user.guest? && user.passkeys.exists?
  end

  def pending_second_factor_session
    session[PENDING_SECOND_FACTOR_SESSION_KEY].to_h
  end

  def consume_step_up_challenge
    challenge_session = session.delete(STEP_UP_CHALLENGE_SESSION_KEY).to_h
    challenge = challenge_session["challenge"].to_s
    issued_at = Time.zone.parse(challenge_session["issued_at"].to_s)
    return if challenge.blank? || issued_at.blank?
    return if issued_at < STEP_UP_CHALLENGE_TTL.ago

    challenge
  rescue ArgumentError, TypeError
    nil
  end

  def credential_params
    credential = params.require(:credential).permit(
      :type,
      :id,
      :rawId,
      :authenticatorAttachment,
      clientExtensionResults: {},
      response: %i[
        authenticatorData
        clientDataJSON
        signature
        userHandle
      ]
    ).to_h
    credential.fetch("rawId")
    response = credential.fetch("response")
    response.fetch("authenticatorData")
    response.fetch("clientDataJSON")
    response.fetch("signature")

    credential
  end

  def render_step_up_error
    clear_pending_second_factor

    render json: {
      ok: false,
      error: t("auth.two_factor.passkey.messages.failure"),
      redirect_url: new_user_session_path
    }, status: :unprocessable_content
  end

  def clear_pending_second_factor
    session.delete(PENDING_SECOND_FACTOR_SESSION_KEY)
    session.delete(STEP_UP_CHALLENGE_SESSION_KEY)
  end
end
