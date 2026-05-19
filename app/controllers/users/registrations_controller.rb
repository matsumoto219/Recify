# frozen_string_literal: true

class Users::RegistrationsController < Devise::RegistrationsController
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
    prev_unconfirmed_email = resource.unconfirmed_email if resource.respond_to?(:unconfirmed_email)
    password_update = password_update_request?
    update_context = params[:update_context].presence
    security_update = update_context == "security" || password_update
    success_path = security_update ? settings_security_path : settings_path
    failure_template = security_update ? "settings/security" : "settings/account"

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
      if security_update
        update_resource(resource, account_update_params)
      else
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

  def password_change_blank?
    current_password = account_update_params[:current_password].to_s
    password = account_update_params[:password].to_s
    password_confirmation = account_update_params[:password_confirmation].to_s

    current_password.present? && password.blank? && password_confirmation.blank?
  end

  def password_update_request?
    account_update_params[:password].present? ||
      account_update_params[:password_confirmation].present?
  end

  def avatar_storage_quota_exceeded?(resource, uploaded_avatar)
    return false if uploaded_avatar.blank?

    excluding_blob = resource.avatar.blob if resource.avatar.attached?

    !resource.storage_can_add?(uploaded_avatar.size, excluding_blob: excluding_blob)
  end

  def remove_avatar_requested?
    params[:remove_avatar] == "1"
  end

  # If you have extra params to permit, append them to the sanitizer.
  def configure_account_update_params
    devise_parameter_sanitizer.permit(:account_update, keys: [ :name, :avatar ])
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
