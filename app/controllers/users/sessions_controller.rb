# frozen_string_literal: true

class Users::SessionsController < Devise::SessionsController
  # before_action :configure_sign_in_params, only: [:create]

  # GET /resource/sign_in
  # def new
  #   super
  # end

  # POST /resource/sign_in
  def create
    self.resource = warden.authenticate(auth_options)

    if resource
      set_flash_message!(:notice, :signed_in)
      sign_in(resource_name, resource)
      respond_with resource, location: after_sign_in_path_for(resource)
    else
      self.resource = resource_class.new(sign_in_params)
      apply_sign_in_error_states
      flash.now[:alert] = I18n.t("devise.failure.invalid", authentication_keys: resource_class.authentication_keys.join("/")).strip
      clean_up_passwords(resource)
      set_minimum_password_length
      respond_with resource, status: :unprocessable_content
    end
  end

  # DELETE /resource/sign_out
  # def destroy
  #   super
  # end

  protected

  def apply_sign_in_error_states
    email_value = sign_in_params[:email].to_s.strip
    password_value = sign_in_params[:password].to_s

    if email_value.blank?
      resource.errors.add(:email, :blank)
    else
      resource.errors.add(:email, :invalid)
    end

    if password_value.blank?
      resource.errors.add(:password, :blank)
    else
      resource.errors.add(:password, :invalid)
    end
  end

  def sign_in_params
    devise_parameter_sanitizer.sanitize(:sign_in)
  end

  # If you have extra params to permit, append them to the sanitizer.
  # def configure_sign_in_params
  #   devise_parameter_sanitizer.permit(:sign_in, keys: [:attribute])
  # end
end
