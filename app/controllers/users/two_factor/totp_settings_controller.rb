class Users::TwoFactor::TotpSettingsController < ApplicationController
  SETUP_SESSION_KEY = :totp_setup
  SETUP_TTL = 10.minutes

  before_action :authenticate_user!
  before_action :ensure_two_factor_management_allowed!
  before_action :require_fresh_security_reauthentication!
  before_action :set_no_store_headers, only: %i[new create]

  def new
    return redirect_to settings_security_path(anchor: "two-factor"), notice: t("settings.security.auth.two_factor.messages.already_enabled") if totp_enabled?

    setup = TwoFactor.prepare_totp_setup(user: current_user)
    session[SETUP_SESSION_KEY] = {
      "secret" => setup.secret,
      "issued_at" => Time.current.iso8601,
      "user_id" => current_user.id,
      "session_version" => current_user.session_version.to_i,
      "security_reauthenticated_at" => security_reauthentication_context["authenticated_at"]
    }
    assign_setup_view(setup)
  end

  def create
    return redirect_to settings_security_path(anchor: "two-factor"), notice: t("settings.security.auth.two_factor.messages.already_enabled") if totp_enabled?

    setup_session = current_setup_session
    if setup_session.blank?
      clear_setup_session
      return redirect_to new_settings_security_totp_path, alert: t("settings.security.auth.two_factor.messages.setup_expired")
    end

    confirmation = TwoFactor.confirm_totp_setup(
      user: current_user,
      secret: setup_session.fetch("secret"),
      code: params[:code]
    )
    clear_setup_session
    @recovery_codes = confirmation.recovery_codes
    set_no_store_headers
    render "users/two_factor/recovery_codes/show", status: :created
  rescue TwoFactor::VerificationError, ActiveRecord::RecordInvalid
    setup = setup_material_from_session(setup_session)
    assign_setup_view(setup)
    flash.now[:alert] = t("settings.security.auth.two_factor.messages.setup_failed")
    render :new, status: :unprocessable_content
  end

  def destroy
    TwoFactor.disable_totp_for(user: current_user)
    clear_setup_session

    redirect_to settings_security_path(anchor: "two-factor"), notice: t("settings.security.auth.two_factor.messages.disabled")
  end

  private

  def ensure_two_factor_management_allowed!
    return if current_user.confirmed? && !current_user.guest?

    redirect_to settings_security_path, alert: t("settings.security.auth.two_factor.messages.unavailable")
  end

  def totp_enabled?
    current_user.totp_credential&.confirmed?
  end

  def current_setup_session
    setup_session = session[SETUP_SESSION_KEY].to_h
    secret = setup_session["secret"].to_s
    issued_at = Time.zone.parse(setup_session["issued_at"].to_s)
    return if secret.blank? || issued_at.blank?
    return if issued_at < SETUP_TTL.ago
    return unless setup_session["user_id"].to_i == current_user.id
    return unless setup_session["session_version"].to_i == current_user.session_version.to_i
    return unless setup_session["security_reauthenticated_at"] == security_reauthentication_context["authenticated_at"]

    setup_session
  rescue ArgumentError, TypeError
    nil
  end

  def setup_material_from_session(setup_session)
    secret = setup_session.fetch("secret")
    provisioning_uri = TwoFactor.totp_provisioning_uri(user: current_user, secret: secret)
    TwoFactor::SetupMaterial.new(
      secret: secret,
      provisioning_uri: provisioning_uri,
      qr_svg: TwoFactor.totp_qr_svg(provisioning_uri: provisioning_uri)
    )
  end

  def assign_setup_view(setup)
    @totp_secret = setup.secret
    @totp_qr_svg = setup.qr_svg
  end

  def clear_setup_session
    session.delete(SETUP_SESSION_KEY)
  end

  def set_no_store_headers
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
  end

  def security_reauthentication_return_to
    return new_settings_security_totp_path if action_name.in?(%w[new create])

    settings_security_path(anchor: "two-factor")
  end
end
