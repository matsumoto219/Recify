# frozen_string_literal: true

class Users::TwoFactor::PasskeysController < ApplicationController
  include Users::TwoFactor::PendingSecondFactor

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

  before_action -> { require_pending_second_factor!(method: "passkey") }, only: %i[new options create]

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

    complete_pending_second_factor!(
      user: @pending_user,
      sign_in_method: "password_passkey_step_up"
    )

    flash[:notice] = t("auth.sessions.messages.signed_in")
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

  def pending_user_still_allowed?(user)
    super && user.passkeys.exists?
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
    session.delete(STEP_UP_CHALLENGE_SESSION_KEY)

    render json: {
      ok: false,
      error: t("auth.two_factor.passkey.messages.failure"),
      redirect_url: users_two_factor_passkey_path
    }, status: :unprocessable_content
  end
end
