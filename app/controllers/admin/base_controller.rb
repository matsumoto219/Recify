class Admin::BaseController < ApplicationController
  DEFAULT_ADMIN_PASSKEY_REAUTHENTICATION_WINDOW = 5.minutes
  ADMIN_PASSKEY_REAUTHENTICATION_WINDOW = DEFAULT_ADMIN_PASSKEY_REAUTHENTICATION_WINDOW
  ADMIN_PASSKEY_REAUTHENTICATION_WINDOW_SETTING_KEY = "security.admin_passkey_reauth_window_minutes"
  ADMIN_PASSKEY_REAUTHENTICATED_AT_SESSION_KEY = :admin_passkey_reauthenticated_at
  ADMIN_PASSKEY_REAUTHENTICATION_METHOD_SESSION_KEY = :admin_passkey_reauthentication_method

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
    context = admin_reauthentication_context
    context[:method] == "passkey" &&
      context[:reauthenticated_at].present? &&
      context[:reauthenticated_at] >= admin_passkey_reauthentication_window.ago
  end

  def admin_reauthentication_context
    {
      method: session[ADMIN_PASSKEY_REAUTHENTICATION_METHOD_SESSION_KEY].presence,
      reauthenticated_at: parse_admin_reauthenticated_at
    }
  end

  def require_admin_passkey_reauthentication!
    return if admin_passkey_reauthenticated?

    redirect_to new_admin_passkey_reauthentication_path(return_to: request.fullpath),
                alert: t("admin.passkey_reauthentications.messages.required"),
                status: :see_other
  end

  def record_admin_passkey_reauthentication!
    session[ADMIN_PASSKEY_REAUTHENTICATED_AT_SESSION_KEY] = Time.current.iso8601
    session[ADMIN_PASSKEY_REAUTHENTICATION_METHOD_SESSION_KEY] = "passkey"
  end

  def clear_admin_passkey_reauthentication!
    session.delete(ADMIN_PASSKEY_REAUTHENTICATED_AT_SESSION_KEY)
    session.delete(ADMIN_PASSKEY_REAUTHENTICATION_METHOD_SESSION_KEY)
  end

  def admin_passkey_reauthentication_window
    SystemSettings.limit_for(ADMIN_PASSKEY_REAUTHENTICATION_WINDOW_SETTING_KEY).minutes
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
    DEFAULT_ADMIN_PASSKEY_REAUTHENTICATION_WINDOW
  end

  def parse_admin_reauthenticated_at
    value = session[ADMIN_PASSKEY_REAUTHENTICATED_AT_SESSION_KEY].to_s
    return if value.blank?

    Time.zone.parse(value)
  rescue ArgumentError, TypeError
    nil
  end
end
