# frozen_string_literal: true

require "openssl"
require "uri"

class ApplicationController < ActionController::Base
  PUBLIC_LAYOUT_ACTIONS = {
    "announcements" => %w[index show],
    "home" => %w[index],
    "legal" => %w[
      terms
      terms_versions
      terms_version
      privacy
      privacy_versions
      privacy_version
    ]
  }.freeze
  AUTH_HEADER_ACTIONS = {
    "contact_requests" => %w[new create],
    "users/sessions" => %w[new create],
    "users/registrations" => %w[new create],
    "users/passwords" => %w[new create edit update],
    "users/confirmations" => %w[new create],
    "users/unlocks" => %w[new create]
  }.freeze
  PUBLIC_HEADER_ACTIONS = PUBLIC_LAYOUT_ACTIONS.merge(AUTH_HEADER_ACTIONS).freeze

  USER_SESSION_VERSION_SESSION_KEY = :user_session_version
  LEGAL_CONSENT_RETURN_TO_SESSION_KEY = :legal_consent_return_to
  LEGAL_CONSENT_LOCALE = :ja

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
  before_action :record_security_event_request_detections
  before_action :enforce_legal_reconsent!
  before_action :prepare_notifications_dropdown, if: :prepare_notifications_dropdown?

  rescue_from ActionController::InvalidAuthenticityToken, with: :record_csrf_failure_and_raise

  class << self
    def rate_limit_cache_store=(store)
      RateLimitStore.store = store
    end
  end

  helper_method :maintenance_notice_enabled?, :maintenance_notice_title, :maintenance_notice_body,
                :maintenance_mode_login_restricted?, :maintenance_mode_title, :maintenance_mode_body,
                :public_layout_page?, :public_header_page?

  private

  def store_user_session_version(user)
    return unless user&.has_attribute?(:session_version)

    session[USER_SESSION_VERSION_SESSION_KEY] = user.session_version.to_i
  end

  def clear_user_session_version
    session.delete(USER_SESSION_VERSION_SESSION_KEY)
  end

  def public_layout_page?
    PUBLIC_LAYOUT_ACTIONS.fetch(controller_path, []).include?(action_name)
  end

  def public_header_page?
    PUBLIC_HEADER_ACTIONS.fetch(controller_path, []).include?(action_name)
  end

  def enforce_legal_reconsent!
    return unless request.format.html?
    return if legal_reconsent_exempt_request?
    return unless user_signed_in?
    return if current_user.guest?

    unless current_legal_documents_ready?
      return if current_user.admin? && controller_path.start_with?("admin/")

      store_legal_consent_return_to
      redirect_to legal_consent_path,
                  flash: { alert: t("flash.legal_documents.unavailable") },
                  status: :see_other
      return
    end

    requirement = LegalConsents::Requirement.new(user: current_user, locale: legal_consent_locale)
    return unless requirement.required?

    store_legal_consent_return_to
    redirect_to legal_consent_path,
                flash: { warning: t("legal_consents.flash.required") },
                status: :see_other
  end

  def legal_reconsent_exempt_request?
    return true if controller_path == "legal_consents"
    return true if public_layout_page?
    return true if %w[contact_requests errors sitemap guest_sessions].include?(controller_path)
    return true if legal_reconsent_devise_request?

    false
  end

  def legal_reconsent_devise_request?
    case controller_path
    when "users/sessions"
      %w[new create destroy].include?(action_name)
    when "users/registrations"
      %w[new create].include?(action_name)
    when "users/passwords", "users/confirmations", "users/unlocks", "users/passkey_sessions"
      true
    else
      false
    end
  end

  def store_legal_consent_return_to
    return unless request.get? || request.head?
    return unless legal_consent_safe_return_path?(request.fullpath)

    session[LEGAL_CONSENT_RETURN_TO_SESSION_KEY] = request.fullpath
  end

  def legal_consent_safe_return_path?(path)
    path = path.to_s
    return false unless path.start_with?("/")
    return false if path.start_with?("//")

    uri = URI.parse(path)
    uri.host.blank? && uri.scheme.blank?
  rescue URI::InvalidURIError
    false
  end

  def legal_consent_locale
    LEGAL_CONSENT_LOCALE
  end

  def current_legal_documents_ready?
    current_legal_documents_status.ready?
  end

  def current_legal_documents_status
    @current_legal_documents_status ||= LegalDocuments::CurrentStatus.call(locale: legal_consent_locale)
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

  def maintenance_mode_login_restricted?
    maintenance_login_restricted?
  end

  def maintenance_mode_title
    Maintenance.title(user: current_user)
  end

  def maintenance_mode_body
    maintenance_restriction_message
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
    SecurityEvents.record_rate_limit!(
      request: request,
      matched_rule: "rails_rate_limit",
      metadata: {
        controller: params[:controller],
        action: params[:action]
      }
    )

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

  def record_security_event_request_detections
    SecurityEvents.record_request_detections!(
      request: request,
      actor_user: security_event_actor_user,
      params: security_event_detection_params
    )
  end

  def security_event_detection_params
    params.except(
      :controller,
      :action,
      :authenticity_token,
      :commit,
      "cf-turnstile-response",
      "g-recaptcha-response"
    )
  end

  def record_csrf_failure_and_raise(exception)
    SecurityEvents.record_csrf_failure!(request: request, actor_user: security_event_actor_user)
    raise exception
  end

  def security_event_actor_user
    request.env["warden"]&.user(scope: :user, run_callbacks: false)
  rescue StandardError
    nil
  end

  def guest_fake_email?(email)
    email.match?(/\Aguest_[0-9a-f]{16}@example\.com\z/i)
  end

  def rate_limit_hmac_secret
    @rate_limit_hmac_secret ||= Rails.application.key_generator.generate_key("recify/rate-limit/email", 32)
  end
end
