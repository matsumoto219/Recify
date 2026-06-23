# frozen_string_literal: true

class Users::ConfirmationsController < Devise::ConfirmationsController
  rate_limit to: 3,
             within: 10.minutes,
             by: :rate_limit_email_digest,
             with: :rate_limit_exceeded,
             store: ApplicationController::RateLimitStore,
             name: "confirmation/email",
             only: :create,
             if: :rate_limit_email_present?

  prepend_before_action :enforce_maintenance_restriction!, only: :create
  before_action :verify_turnstile!, only: :create, unless: :turnstile_exempt_confirmation_context?

  # GET /resource/confirmation/new
  # def new
  #   super
  # end

  # POST /resource/confirmation
  def create
    super
    keep_flash_until_manual_dismiss(:notice)
  end

  # GET /resource/confirmation?confirmation_token=abcdef
  # def show
  #   super
  # end

  protected

  def enforce_maintenance_restriction!
    return unless maintenance_login_restricted?

    self.resource = resource_class.new(email: params.dig(resource_name, :email).to_s)
    flash.now[:alert] = maintenance_restriction_message
    render :new, status: :unprocessable_content
  end

  def verify_turnstile!
    result = BotProtection.verify_turnstile(
      token: params["cf-turnstile-response"],
      remote_ip: request.remote_ip
    )

    return if result.success?

    self.resource = resource_class.new(email: params.dig(resource_name, :email).to_s)
    flash.now[:alert] = t("flash.bot_protection.verification_failed")
    render :new, status: :unprocessable_content
  end

  def turnstile_exempt_confirmation_context?
    user_signed_in?
  end

  # The path used after resending confirmation instructions.
  def after_resending_confirmation_instructions_path_for(resource_name)
    return new_session_path(resource_name) unless user_signed_in?

    if current_user.guest_registration_pending?
      settings_security_path(anchor: "guest-registration")
    elsif current_user.pending_reconfirmation?
      settings_security_path(anchor: "email")
    else
      settings_security_path
    end
  end

  # The path used after confirmation.
  # def after_confirmation_path_for(resource_name, resource)
  #   super(resource_name, resource)
  # end
end
