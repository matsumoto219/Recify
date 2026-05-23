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

  # GET /resource/confirmation/new
  # def new
  #   super
  # end

  # POST /resource/confirmation
  # def create
  #   super
  # end

  # GET /resource/confirmation?confirmation_token=abcdef
  # def show
  #   super
  # end

  protected

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
