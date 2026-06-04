# frozen_string_literal: true

class Users::PasskeySessionsController < ApplicationController
  AUTHENTICATION_CHALLENGE_SESSION_KEY = :passkey_authentication_challenge
  AUTHENTICATION_CHALLENGE_TTL = 5.minutes

  rate_limit to: 10,
             within: 5.minutes,
             by: :rate_limit_remote_ip_key,
             with: :rate_limit_exceeded,
             store: ApplicationController::RateLimitStore,
             name: "passkey_login/options/ip",
             only: :options

  rate_limit to: 10,
             within: 5.minutes,
             by: :rate_limit_remote_ip_key,
             with: :rate_limit_exceeded,
             store: ApplicationController::RateLimitStore,
             name: "passkey_login/create/ip",
             only: :create

  def options
    options = Passkeys.discoverable_authentication_options
    session[AUTHENTICATION_CHALLENGE_SESSION_KEY] = {
      "challenge" => options.challenge,
      "issued_at" => Time.current.iso8601
    }

    render json: { publicKey: options.as_json }
  end

  def create
    challenge = consume_authentication_challenge
    return render_login_error if challenge.blank?

    result = Passkeys.verify_discoverable_authentication(
      credential: credential_params,
      challenge: challenge
    ) do |user|
      raise Passkeys::AuthenticationError, "login_not_allowed" unless passkey_login_allowed?(user)
    end
    user = result.user

    clear_pending_second_factor
    sign_in(:user, user)
    store_user_session_version(user)
    UserSessions.record_sign_in(user: user, request: request, session: session, method: "passkey")
    flash[:notice] = t("auth.sessions.messages.signed_in")
    render json: {
      ok: true,
      redirect_url: after_sign_in_path_for(user)
    }
  rescue ActiveRecord::RecordNotFound,
         Passkeys::AuthenticationError,
         WebAuthn::Error,
         WebAuthn::VerificationError,
         KeyError,
         ActionController::ParameterMissing
    render_login_error
  end

  private

  def passkey_login_allowed?(user)
    user.active_for_authentication? && !user.guest? && Maintenance.login_allowed_for?(user)
  end

  def clear_pending_second_factor
    session.delete(Users::SessionsController::PENDING_SECOND_FACTOR_SESSION_KEY)
    session.delete(Users::TwoFactor::PasskeysController::STEP_UP_CHALLENGE_SESSION_KEY)
  end

  def consume_authentication_challenge
    challenge_session = session.delete(AUTHENTICATION_CHALLENGE_SESSION_KEY).to_h
    challenge = challenge_session["challenge"].to_s
    issued_at = Time.zone.parse(challenge_session["issued_at"].to_s)
    return if challenge.blank? || issued_at.blank?
    return if issued_at < AUTHENTICATION_CHALLENGE_TTL.ago

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

  def render_login_error
    render json: {
      ok: false,
      error: t("auth.sessions.passkey.messages.failure")
    }, status: :unprocessable_content
  end
end
