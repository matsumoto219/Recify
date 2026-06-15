class ContactRequestsController < ApplicationController
  rate_limit to: 5,
             within: 1.day,
             by: :rate_limit_current_user_key,
             with: :rate_limit_exceeded,
             store: ApplicationController::RateLimitStore,
             name: "contact/user",
             only: :create,
             if: :rate_limit_registered_contact_user?

  rate_limit to: 3,
             within: 1.day,
             by: :rate_limit_remote_ip_key,
             with: :rate_limit_exceeded,
             store: ApplicationController::RateLimitStore,
             name: "contact/ip",
             only: :create,
             if: :rate_limit_guest_or_public_contact?

  rate_limit to: 3,
             within: 1.day,
             by: :rate_limit_contact_email_digest,
             with: :rate_limit_exceeded,
             store: ApplicationController::RateLimitStore,
             name: "contact/email",
             only: :create,
             if: :rate_limit_contact_email_present?

  prepend_before_action :enforce_maintenance_restriction!, only: :create
  before_action :verify_turnstile!, only: :create

  def new
    @contact_request = build_contact_request
  end

  def create
    result = ContactRequests.create(user: contact_user, params: contact_request_params, request: request)

    if result.success?
      redirect_to contact_path, notice: t("contact_requests.messages.created"), status: :see_other
    else
      @contact_request = result.contact_request
      flash.now[:alert] = t("contact_requests.messages.create_failed")
      render :new, status: :unprocessable_content
    end
  end

  private

  def enforce_maintenance_restriction!
    return unless maintenance_login_restricted?

    @contact_request = build_contact_request
    @contact_request.assign_attributes(contact_request_params.except(:email, :company_name))
    flash.now[:alert] = maintenance_restriction_message
    render :new, status: :unprocessable_content
  end

  def build_contact_request
    ContactRequest.new(
      sender_name: default_sender_name,
      email: default_contact_email,
      source: contact_source,
      status: "open"
    )
  end

  def contact_user
    current_user if user_signed_in?
  end

  def default_contact_email
    return current_user.email if user_signed_in? && !current_user.guest?

    params.dig(:contact_request, :email).to_s
  end

  def default_sender_name
    return current_user.name if user_signed_in? && !current_user.guest?

    params.dig(:contact_request, :sender_name).to_s
  end

  def contact_source
    return "public" unless user_signed_in?
    return "guest" if current_user.guest?

    "authenticated"
  end

  def contact_request_params
    params.fetch(:contact_request, {}).permit(:sender_name, :email, :category, :subject, :body, :company_name)
  end

  def verify_turnstile!
    result = BotProtection.verify_turnstile(
      token: params["cf-turnstile-response"],
      remote_ip: request.remote_ip
    )

    return if result.success?

    @contact_request = build_contact_request
    @contact_request.assign_attributes(contact_request_params.except(:email, :company_name))
    flash.now[:alert] = t("flash.bot_protection.verification_failed")
    render :new, status: :unprocessable_content
  end

  def rate_limit_registered_contact_user?
    user_signed_in? && !current_user.guest?
  end

  def rate_limit_guest_or_public_contact?
    !user_signed_in? || current_user.guest?
  end

  def rate_limit_contact_email_present?
    rate_limit_contact_email_digest.present?
  end

  def rate_limit_contact_email_digest
    email =
      if user_signed_in? && !current_user.guest?
        nil
      else
        params.dig(:contact_request, :email).to_s.strip.downcase
      end

    return if email.blank?
    return if guest_fake_email?(email)

    ContactRequests.email_digest(email)
  end
end
