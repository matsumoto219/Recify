class Admin::BaseController < ApplicationController
  ADMIN_PASSKEY_REAUTHENTICATED_AT_SESSION_KEY = :admin_passkey_reauthenticated_at
  ADMIN_PASSKEY_REAUTHENTICATION_METHOD_SESSION_KEY = :admin_passkey_reauthentication_method
  ADMIN_PASSKEY_REAUTHENTICATION_USER_ID_SESSION_KEY = :admin_passkey_reauthentication_user_id
  ADMIN_PASSKEY_REAUTHENTICATION_SESSION_VERSION_SESSION_KEY = :admin_passkey_reauthentication_session_version
  ADMIN_PASSKEY_REAUTHENTICATION_EXPIRES_AT_SESSION_KEY = :admin_passkey_reauthentication_expires_at

  around_action :with_admin_locale
  before_action :require_admin!

  helper_method :admin_passkey_reauthenticated?, :admin_reauthentication_context

  private

  def with_admin_locale(&action)
    I18n.with_locale(admin_locale, &action)
  end

  def admin_locale
    :ja
  end

  def require_admin!
    return if current_user&.admin? &&
              current_user.active_for_authentication? &&
              !current_user.guest?

    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end

  def admin_passkey_reauthenticated?
    Admin.passkey_reauth_fresh?(admin_reauthentication_context, user: current_user)
  end

  def admin_reauthentication_context
    {
      method: session[ADMIN_PASSKEY_REAUTHENTICATION_METHOD_SESSION_KEY].presence,
      reauthenticated_at: parse_admin_reauthenticated_at,
      user_id: session[ADMIN_PASSKEY_REAUTHENTICATION_USER_ID_SESSION_KEY],
      session_version: session[ADMIN_PASSKEY_REAUTHENTICATION_SESSION_VERSION_SESSION_KEY],
      expires_at: parse_admin_reauthentication_expires_at
    }
  end

  def require_admin_passkey_reauthentication!
    return if admin_passkey_reauthenticated?

    redirect_to new_admin_passkey_reauthentication_path(return_to: request.fullpath),
                alert: t("admin.passkey_reauthentications.messages.required"),
                status: :see_other
  end

  def record_admin_passkey_reauthentication!
    reauthenticated_at = Time.current
    session[ADMIN_PASSKEY_REAUTHENTICATED_AT_SESSION_KEY] = reauthenticated_at.iso8601
    session[ADMIN_PASSKEY_REAUTHENTICATION_METHOD_SESSION_KEY] = "passkey"
    session[ADMIN_PASSKEY_REAUTHENTICATION_USER_ID_SESSION_KEY] = current_user.id
    session[ADMIN_PASSKEY_REAUTHENTICATION_SESSION_VERSION_SESSION_KEY] = current_user.session_version.to_i
    session[ADMIN_PASSKEY_REAUTHENTICATION_EXPIRES_AT_SESSION_KEY] =
      (reauthenticated_at + Admin.passkey_reauth_window_duration).iso8601
  end

  def clear_admin_passkey_reauthentication!
    session.delete(ADMIN_PASSKEY_REAUTHENTICATED_AT_SESSION_KEY)
    session.delete(ADMIN_PASSKEY_REAUTHENTICATION_METHOD_SESSION_KEY)
    session.delete(ADMIN_PASSKEY_REAUTHENTICATION_USER_ID_SESSION_KEY)
    session.delete(ADMIN_PASSKEY_REAUTHENTICATION_SESSION_VERSION_SESSION_KEY)
    session.delete(ADMIN_PASSKEY_REAUTHENTICATION_EXPIRES_AT_SESSION_KEY)
  end

  def parse_admin_reauthenticated_at
    value = session[ADMIN_PASSKEY_REAUTHENTICATED_AT_SESSION_KEY].to_s
    return if value.blank?

    Time.zone.parse(value)
  rescue ArgumentError, TypeError
    nil
  end

  def parse_admin_reauthentication_expires_at
    value = session[ADMIN_PASSKEY_REAUTHENTICATION_EXPIRES_AT_SESSION_KEY].to_s
    return if value.blank?

    Time.zone.parse(value)
  rescue ArgumentError, TypeError
    nil
  end
end
