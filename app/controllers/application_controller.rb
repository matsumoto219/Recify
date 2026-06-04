# frozen_string_literal: true

require "openssl"

class ApplicationController < ActionController::Base
  USER_SESSION_VERSION_SESSION_KEY = :user_session_version

  class RateLimitStore
    class << self
      attr_writer :store

      def increment(...)
        store.increment(...)
      end

      def clear
        store.clear if store.respond_to?(:clear)
      end

      private

      def store
        @store || Rails.cache
      end
    end
  end

  include Pagy::Method

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :enforce_user_session_version!, unless: :skip_user_session_version_enforcement?
  before_action :enforce_maintenance_existing_session!
  before_action :prepare_notifications_dropdown, if: :prepare_notifications_dropdown?

  class << self
    def rate_limit_cache_store=(store)
      RateLimitStore.store = store
    end
  end

  helper_method :maintenance_notice_enabled?, :maintenance_notice_title, :maintenance_notice_body

  private

  def store_user_session_version(user)
    return unless user&.has_attribute?(:session_version)

    session[USER_SESSION_VERSION_SESSION_KEY] = user.session_version.to_i
  end

  def clear_user_session_version
    session.delete(USER_SESSION_VERSION_SESSION_KEY)
  end

  def enforce_user_session_version!
    return unless user_signed_in?
    return unless current_user&.has_attribute?(:session_version)

    if session[USER_SESSION_VERSION_SESSION_KEY].nil?
      store_user_session_version(current_user)
      touch_current_user_session
      return
    end

    if session[USER_SESSION_VERSION_SESSION_KEY].to_i == current_user.session_version.to_i
      touch_current_user_session
      return
    end

    clear_user_session_version
    sign_out(:user)
    redirect_to new_user_session_path,
                alert: t("auth.sessions.messages.session_expired"),
                status: :see_other
  end

  def skip_user_session_version_enforcement?
    is_a?(Users::SessionsController) && action_name == "create"
  end

  def enforce_maintenance_existing_session!
    return unless authenticated_user_session?

    user = current_user
    return unless user
    return unless maintenance_login_restricted?
    return if Maintenance.admin_bypass_user?(user)

    message = maintenance_restriction_message(user: user)
    UserSessions.record_sign_out(user: user, session: session)
    clear_user_session_version
    sign_out(:user)
    redirect_to new_user_session_path, alert: message, status: :see_other
  end

  def authenticated_user_session?
    session["warden.user.user.key"].present?
  end

  def maintenance_login_restricted?
    Maintenance.login_restricted?(user: current_user)
  end

  def maintenance_restriction_message(user: nil)
    Maintenance.body(user: user || current_user)
  end

  def touch_current_user_session
    UserSessions.touch_current(user: current_user, request: request, session: session)
  end

  def maintenance_notice_enabled?
    return false unless user_signed_in?

    SystemSettings.enabled?("ui.maintenance_notice_enabled", user: current_user)
  end

  def maintenance_notice_title
    maintenance_notice_text("ui.maintenance_notice_title", fallback_key: "shared.maintenance_notice.title")
  end

  def maintenance_notice_body
    maintenance_notice_text("ui.maintenance_notice_body", fallback_key: "shared.maintenance_notice.body")
  end

  def maintenance_notice_text(key, fallback_key:)
    SystemSettings.value_for(key, user: current_user).to_s.presence || I18n.t(fallback_key)
  end

  def prepare_notifications_dropdown?
    request.get? && user_signed_in? && request.format.html?
  end

  def prepare_notifications_dropdown
    @notifications_dropdown = notifications_dropdown_items
  end

  def notifications_dropdown_items
    Notification.preload_known_notifiables(
      current_user.notifications.recent.limit(Notification::DROPDOWN_LIMIT).to_a
    )
  end

  def rate_limit_email_digest
    email = normalized_rate_limit_email
    return if email.blank?

    OpenSSL::HMAC.hexdigest("SHA256", rate_limit_hmac_secret, email)
  end

  def rate_limit_email_present?
    normalized_rate_limit_email.present?
  end

  def rate_limit_current_user_ip_key
    return if current_user.blank?

    [ "user", current_user.id, "ip", request.remote_ip ].join(":")
  end

  def rate_limit_update_context_user_ip_key
    user_ip_key = rate_limit_current_user_ip_key
    return if user_ip_key.blank?

    [ "context", params[:update_context].to_s, user_ip_key ].join(":")
  end

  def rate_limit_current_user_key
    return if current_user.blank?

    [ "user", current_user.id ].join(":")
  end

  def rate_limit_remote_ip_key
    request.remote_ip
  end

  def rate_limit_guest_registration_context?
    user_signed_in? && params[:update_context].to_s == "guest_registration"
  end

  def rate_limit_email_change_context?
    user_signed_in? && params[:update_context].to_s == "email"
  end

  def rate_limit_signed_in?
    user_signed_in?
  end

  def rate_limit_exceeded
    message = t("flash.rate_limit.too_many_requests")

    respond_to do |format|
      format.turbo_stream do
        flash.now[:alert] = message
        render turbo_stream: turbo_stream.update("flash", partial: "shared/ui/feedback/flash"),
               status: :too_many_requests
      end

      format.json do
        render json: { error: message }, status: :too_many_requests
      end

      format.html do
        flash.now[:alert] = message
        render "errors/too_many_requests", status: :too_many_requests
      end

      format.any do
        render plain: message, status: :too_many_requests
      end
    end
  end

  def normalized_rate_limit_email
    email = params.dig(:user, :email).to_s.strip.downcase
    return if email.blank?
    return if guest_fake_email?(email)

    email
  end

  def guest_fake_email?(email)
    email.match?(/\Aguest_[0-9a-f]{16}@example\.com\z/i)
  end

  def rate_limit_hmac_secret
    @rate_limit_hmac_secret ||= Rails.application.key_generator.generate_key("recify/rate-limit/email", 32)
  end
end
