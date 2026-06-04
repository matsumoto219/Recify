# frozen_string_literal: true

class Users::PasswordsController < Devise::PasswordsController
  rate_limit to: 3,
             within: 10.minutes,
             by: :rate_limit_email_digest,
             with: :rate_limit_exceeded,
             store: ApplicationController::RateLimitStore,
             name: "password-reset/email",
             only: :create,
             if: :rate_limit_email_present?

  before_action :verify_turnstile!, only: :create

  # GET /resource/password/new
  # def new
  #   super
  # end

  # POST /resource/password
  def create
    super do |resource|
      set_flash_from_resource_errors(resource) if resource.errors.any?
    end
  end

  # GET /resource/password/edit?reset_password_token=abcdef
  # def edit
  #   super
  # end

  # PUT /resource/password
  # def update
  #   super
  # end

  protected

  def set_flash_from_resource_errors(resource)
    flash.now[:alert] = resource.errors.full_messages
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

  # def after_resetting_password_path_for(resource)
  #   super(resource)
  # end

  # The path used after sending reset password instructions
  # def after_sending_reset_password_instructions_path_for(resource_name)
  #   super(resource_name)
  # end
end
