# frozen_string_literal: true

class Admin::PasskeyReauthenticationsController < Admin::BaseController
  CHALLENGE_SESSION_KEY = :admin_passkey_reauthentication_challenge
  CHALLENGE_TTL = 5.minutes
  RETURN_TO_SESSION_KEY = :admin_passkey_reauthentication_return_to

  rate_limit to: 10,
             within: 5.minutes,
             by: :rate_limit_remote_ip_key,
             with: :rate_limit_exceeded,
             store: ApplicationController::RateLimitStore,
             name: "admin_passkey_reauthentication/options/ip",
             only: :options

  rate_limit to: 10,
             within: 5.minutes,
             by: :rate_limit_remote_ip_key,
             with: :rate_limit_exceeded,
             store: ApplicationController::RateLimitStore,
             name: "admin_passkey_reauthentication/create/ip",
             only: :create

  def new
    session[RETURN_TO_SESSION_KEY] = safe_return_to(params[:return_to]) if params[:return_to].present?
    @admin_passkey_registered = current_user.passkeys.exists?
    @admin_passkey_reauth_window_minutes = Admin.passkey_reauth_window_duration.to_i / 1.minute.to_i
  end

  def options
    return render_reauthentication_error("passkey_not_registered", status: :unprocessable_content) if current_user.passkeys.none?

    options = Passkeys.reauthentication_options(user: current_user)
    session[CHALLENGE_SESSION_KEY] = {
      "challenge" => options.challenge,
      "issued_at" => Time.current.iso8601,
      "user_id" => current_user.id,
      "session_version" => current_user.session_version.to_i
    }

    render json: { publicKey: options.as_json }
  end

  def create
    challenge = consume_reauthentication_challenge
    return render_reauthentication_error("challenge_missing") if challenge.blank?

    Passkeys.verify_reauthentication(
      user: current_user,
      credential: credential_params,
      challenge: challenge
    ) do |user|
      raise Passkeys::AuthenticationError, "admin_reauthentication_not_allowed" unless admin_reauthentication_allowed?(user)
    end

    record_reauthentication_audit!(outcome: "succeeded")
    record_admin_passkey_reauthentication!

    render json: {
      ok: true,
      redirect_url: consume_return_to
    }
  rescue ActiveRecord::RecordNotFound,
         Passkeys::AuthenticationError,
         WebAuthn::Error,
         WebAuthn::VerificationError,
         KeyError,
         ActionController::ParameterMissing
    render_reauthentication_error("passkey_reauthentication_failed")
  end

  private

  def admin_reauthentication_allowed?(user)
    user == current_user && user.admin? && user.active_for_authentication? && !user.guest? && user.passkeys.exists?
  end

  def consume_reauthentication_challenge
    challenge_session = session.delete(CHALLENGE_SESSION_KEY).to_h
    challenge = challenge_session["challenge"].to_s
    issued_at = Time.zone.parse(challenge_session["issued_at"].to_s)
    return if challenge.blank? || issued_at.blank?
    return if issued_at < CHALLENGE_TTL.ago
    return unless challenge_session["user_id"].to_i == current_user.id.to_i
    return unless challenge_session["session_version"].to_i == current_user.session_version.to_i

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

  def render_reauthentication_error(error_code, status: :unprocessable_content)
    session.delete(CHALLENGE_SESSION_KEY)
    clear_admin_passkey_reauthentication!
    record_reauthentication_audit!(outcome: "failed", error_code: error_code)

    render json: {
      ok: false,
      error: t("admin.passkey_reauthentications.messages.failed")
    }, status: status
  end

  def record_reauthentication_audit!(outcome:, error_code: nil)
    AuditLogs.record_admin_action!(
      actor: current_user,
      action: outcome == "succeeded" ? "admin.passkey_reauthentication.succeeded" : "admin.passkey_reauthentication.failed",
      outcome: outcome,
      error_code: error_code,
      metadata: { method: "passkey" },
      request: request
    )
  end

  def safe_return_to(value)
    url_from(value) || admin_root_path
  end

  def consume_return_to
    safe_return_to(session.delete(RETURN_TO_SESSION_KEY))
  end
end
