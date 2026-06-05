class Users::PasskeysController < ApplicationController
  REGISTRATION_CHALLENGE_SESSION_KEY = :passkey_registration_challenge
  REGISTRATION_CHALLENGE_TTL = 5.minutes

  before_action :authenticate_user!
  before_action :ensure_passkey_registration_allowed!
  before_action :ensure_passkey_registration_limit_available!, only: %i[options create]

  def options
    options = Passkeys.registration_options(user: current_user)
    session[REGISTRATION_CHALLENGE_SESSION_KEY] = {
      "challenge" => options.challenge,
      "issued_at" => Time.current.iso8601
    }

    render json: { publicKey: options.as_json }
  end

  def create
    challenge = consume_registration_challenge
    if challenge.blank?
      return render_passkey_error(t("settings.security.auth.passkey.messages.challenge_missing"), :unprocessable_content)
    end

    passkey = Passkeys.verify_registration(
      user: current_user,
      credential: credential_params,
      challenge: challenge,
      label: params[:label].to_s.strip.presence
    )

    render json: {
      ok: true,
      passkey: passkey_json(passkey),
      message: t("settings.security.auth.passkey.messages.success")
    }, status: :created
  rescue ActiveRecord::RecordInvalid => error
    render_passkey_error(error.record.errors.full_messages.to_sentence.presence || t("settings.security.auth.passkey.messages.failure"), :unprocessable_content)
  rescue WebAuthn::Error, WebAuthn::VerificationError, KeyError, ActionController::ParameterMissing
    render_passkey_error(t("settings.security.auth.passkey.messages.failure"), :unprocessable_content)
  end

  def destroy
    passkey = current_user.passkeys.find_by!(uid: params[:uid])
    passkey.destroy!

    redirect_to settings_security_path(anchor: "passkeys"), notice: t("settings.security.auth.passkey.messages.deleted")
  end

  private

  def ensure_passkey_registration_allowed!
    return if current_user.confirmed? && !current_user.guest?

    respond_to do |format|
      format.html do
        redirect_to settings_security_path, alert: t("settings.security.auth.passkey.messages.unavailable")
      end
      format.json do
        render json: {
          ok: false,
          error: t("settings.security.auth.passkey.messages.unavailable")
        }, status: :forbidden
      end
    end
  end

  def ensure_passkey_registration_limit_available!
    return unless Passkeys.registration_limit_reached?(current_user)

    session.delete(REGISTRATION_CHALLENGE_SESSION_KEY) if action_name == "create"

    respond_to do |format|
      format.html do
        redirect_to settings_security_path(anchor: "passkeys"),
                    alert: t("settings.security.auth.passkey.messages.limit_reached", count: Passkeys.registration_limit)
      end
      format.json do
        render json: {
          ok: false,
          error: t("settings.security.auth.passkey.messages.limit_reached", count: Passkeys.registration_limit)
        }, status: :unprocessable_content
      end
    end
  end

  def consume_registration_challenge
    challenge_session = session.delete(REGISTRATION_CHALLENGE_SESSION_KEY).to_h
    challenge = challenge_session["challenge"].to_s
    issued_at = Time.zone.parse(challenge_session["issued_at"].to_s)
    return if challenge.blank? || issued_at.blank?
    return if issued_at < REGISTRATION_CHALLENGE_TTL.ago

    challenge
  rescue ArgumentError, TypeError
    nil
  end

  def credential_params
    params.require(:credential).permit(
      :type,
      :id,
      :rawId,
      :authenticatorAttachment,
      clientExtensionResults: {},
      response: [
        :attestationObject,
        :clientDataJSON,
        { transports: [] }
      ]
    ).to_h
  end

  def render_passkey_error(message, status)
    render json: { ok: false, error: message }, status: status
  end

  def passkey_json(passkey)
    {
      id: passkey.id,
      label: passkey.label,
      created_at: passkey.created_at,
      last_used_at: passkey.last_used_at
    }
  end
end
