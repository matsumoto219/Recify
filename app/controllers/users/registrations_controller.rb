# frozen_string_literal: true

class Users::RegistrationsController < Devise::RegistrationsController
  SUPPORTED_UPDATE_CONTEXTS = %w[account security email guest_registration].freeze

  # before_action :configure_sign_up_params, only: [:create]
  before_action :configure_account_update_params, only: [ :update ]

  # GET /resource/sign_up
  # def new
  #   super
  # end

  # POST /resource
  def create
    super do |resource|
      set_flash_from_resource_errors(resource) if resource.errors.any?
    end
  end

  # GET /resource/edit
  # def edit
  #   super
  # end

  # PUT /resource
  def update
    self.resource = resource_class.to_adapter.get!(send(:"current_#{resource_name}").to_key)
    update_context = normalized_update_context

    unless update_context
      redirect_unsupported_update_context
      return
    end

    prev_unconfirmed_email = resource.unconfirmed_email if resource.respond_to?(:unconfirmed_email)

    if update_context == "email"
      update_email
      return
    end

    if update_context == "guest_registration"
      update_guest_registration
      return
    end

    security_update = update_context == "security"
    account_update = update_context == "account" && !security_update
    success_path = update_success_path(update_context, security_update)
    failure_template = update_failure_template(update_context, security_update)

    if security_update && password_change_blank?
      resource.errors.add(:password, :blank)
      resource.errors.add(:password_confirmation, :blank)
      clean_up_passwords resource
      set_minimum_password_length
      set_flash_from_resource_errors(resource)
      render failure_template, status: :unprocessable_content
      return
    end

    resource_updated = (
      if account_update
        profile_params = account_update_params.except(:current_password, :password, :password_confirmation)
        if avatar_storage_quota_exceeded?(resource, profile_params[:avatar])
          resource.errors.add(:avatar, :storage_quota_exceeded)
          flash.now[:alert] = t("flash.storage.quota_exceeded")
          render failure_template, status: :unprocessable_content
          return
        end

        resource_updated = resource.update_without_password(profile_params)
        resource.avatar.purge if resource_updated && remove_avatar_requested? && !profile_params[:avatar].present? && resource.avatar.attached?
        resource_updated
      else
        update_resource(resource, account_update_params)
      end
    )

    yield resource if block_given?

    if resource_updated
      set_flash_message_for_update(resource, prev_unconfirmed_email)
      bypass_sign_in resource, scope: resource_name if sign_in_after_change_password?
      redirect_to success_path
    else
      clean_up_passwords resource
      set_minimum_password_length
      set_flash_from_resource_errors(resource)
      render failure_template, status: :unprocessable_content
    end
  end

  # DELETE /resource
  # def destroy
  #   super
  # end

  # GET /resource/cancel
  # Forces the session data which is usually expired after sign
  # in to be expired now. This is useful if the user wants to
  # cancel oauth signing in/up in the middle of the process,
  # removing all OAuth session data.
  # def cancel
  #   super
  # end

  protected

  def set_flash_from_resource_errors(resource)
    flash.now[:alert] = resource.errors.full_messages
  end

  def update_email
    if resource.guest?
      reject_security_update(t("flash.users.email_change.guest_not_allowed"))
      return
    end

    if update_resource(resource, email_update_params)
      flash[:notice] = t("flash.users.email_change.confirmation_sent")
      bypass_sign_in resource, scope: resource_name if sign_in_after_change_password?
      redirect_to settings_security_path(anchor: "email")
    else
      clean_up_passwords resource
      set_minimum_password_length
      set_flash_from_resource_errors(resource)
      render "settings/security", status: :unprocessable_content
    end
  end

  def update_guest_registration
    unless resource.guest?
      reject_security_update(t("flash.users.guest_registration.not_allowed"))
      return
    end

    if resource.start_guest_registration(guest_registration_params)
      flash[:notice] = t("flash.users.guest_registration.confirmation_sent")
      bypass_sign_in resource, scope: resource_name
      redirect_to settings_security_path(anchor: "guest-registration")
    else
      clean_up_passwords resource
      set_minimum_password_length
      set_flash_from_resource_errors(resource)
      render "settings/security", status: :unprocessable_content
    end
  end

  def reject_security_update(message)
    resource.errors.add(:base, message)
    clean_up_passwords resource
    set_minimum_password_length
    set_flash_from_resource_errors(resource)
    render "settings/security", status: :unprocessable_content
  end

  def redirect_unsupported_update_context
    redirect_to unsupported_update_context_path,
                alert: t("flash.users.unsupported_update_context")
  end

  def unsupported_update_context_path
    return settings_security_path(anchor: "guest-registration") if resource.guest?

    settings_security_path
  end

  def password_change_blank?
    current_password = account_update_params[:current_password].to_s
    password = account_update_params[:password].to_s
    password_confirmation = account_update_params[:password_confirmation].to_s

    current_password.present? && password.blank? && password_confirmation.blank?
  end

  def avatar_storage_quota_exceeded?(resource, uploaded_avatar)
    return false if uploaded_avatar.blank?

    excluding_blob = resource.avatar.blob if resource.avatar.attached?

    !resource.storage_can_add?(uploaded_avatar.size, excluding_blob: excluding_blob)
  end

  def remove_avatar_requested?
    params[:remove_avatar] == "1"
  end

  def normalized_update_context
    update_context = params[:update_context].presence
    return update_context if SUPPORTED_UPDATE_CONTEXTS.include?(update_context)

    nil
  end

  def update_success_path(update_context, security_update)
    return settings_security_path if security_update
    return settings_path if update_context == "account"

    after_update_path_for(resource)
  end

  def update_failure_template(update_context, security_update)
    return "settings/security" if security_update
    return "settings/account" if update_context == "account"

    "devise/registrations/edit"
  end

  # If you have extra params to permit, append them to the sanitizer.
  def configure_account_update_params
    devise_parameter_sanitizer.permit(:account_update, keys: [ :name, :avatar ])
  end

  def email_update_params
    account_update_params.slice(:email, :current_password)
  end

  def guest_registration_params
    account_update_params.slice(:email, :password, :password_confirmation)
  end

  # The path used after sign up.
  # def after_sign_up_path_for(resource)
  #   super(resource)
  # end

  # The path used after sign up for inactive accounts.
  # def after_inactive_sign_up_path_for(resource)
  #   super(resource)
  # end
end
