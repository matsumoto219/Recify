# frozen_string_literal: true

class Users::SessionsController < Devise::SessionsController
  PENDING_SECOND_FACTOR_SESSION_KEY = :pending_second_factor
  PENDING_SECOND_FACTOR_TTL = 5.minutes

  rate_limit to: 5,
             within: 5.minutes,
             by: :rate_limit_email_digest,
             with: :rate_limit_exceeded,
             store: ApplicationController::RateLimitStore,
             name: "login/email",
             only: :create,
             if: :rate_limit_email_present?

  # before_action :configure_sign_in_params, only: [:create]

  # GET /resource/sign_in
  # def new
  #   super
  # end

  # POST /resource/sign_in
  def create
    self.resource = warden.authenticate(password_auth_options)

    if resource
      if passkey_step_up_required?(resource)
        store_pending_second_factor(resource)
        flash[:notice] = t("auth.two_factor.passkey.pending_notice")
        redirect_to users_two_factor_passkey_path, status: :see_other
      else
        set_flash_message!(:notice, :signed_in)
        sign_in(resource_name, resource, force: true)
        respond_with resource, location: after_sign_in_path_for(resource)
      end
    else
      failure_message = warden.message || :invalid
      self.resource = resource_class.new(sign_in_params)
      apply_sign_in_error_states if field_error_sign_in_failure?(failure_message)
      flash.now[:alert] = sign_in_failure_message(failure_message)
      clean_up_passwords(resource)
      set_minimum_password_length
      render :new, status: :unprocessable_content
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

  def field_error_sign_in_failure?(failure_message)
    failure_message.to_sym.in?([ :invalid, :not_found_in_database ])
  end

  def sign_in_failure_message(failure_message)
    I18n.t(
      "devise.failure.#{failure_message}",
      authentication_keys: sign_in_authentication_keys_label,
      default: I18n.t("devise.failure.invalid", authentication_keys: sign_in_authentication_keys_label)
    ).strip
  end

  def sign_in_authentication_keys_label
    keys = resource_class.authentication_keys
    keys = keys.keys if keys.is_a?(Hash)

    keys.map { |key| resource_class.human_attribute_name(key).downcase }.join(I18n.t(:"support.array.words_connector"))
  end

  def password_auth_options
    auth_options.merge(store: false, run_callbacks: false)
  end

  def passkey_step_up_required?(user)
    !user.guest? && user.passkeys.exists?
  end

  def store_pending_second_factor(user)
    session[PENDING_SECOND_FACTOR_SESSION_KEY] = {
      "user_id" => user.id,
      "issued_at" => Time.current.iso8601,
      "remember_me" => ActiveModel::Type::Boolean.new.cast(params.dig(:user, :remember_me)) || false,
      "method" => "password",
      "allowed_methods" => [ "passkey" ]
    }
  end

  # If you have extra params to permit, append them to the sanitizer.
  # def configure_sign_in_params
  #   devise_parameter_sanitizer.permit(:sign_in, keys: [:attribute])
  # end
end
