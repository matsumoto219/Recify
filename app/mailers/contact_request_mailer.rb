class ContactRequestMailer < ApplicationMailer
  class << self
    def admin_notification_enabled?
      notification_email.present?
    end

    def notification_email
      ENV["SUPPORT_NOTIFICATION_EMAIL"].presence ||
        Rails.application.credentials.dig(:support, :notification_email).presence
    end
  end

  def admin_notification(contact_request)
    @contact_request = contact_request
    @admin_url = admin_contact_request_url(contact_request)
    @masked_email = masked_email(contact_request.email)

    mail(
      to: self.class.notification_email,
      subject: t(
        "contact_requests.mailer.admin_notification.subject",
        request_uid: contact_request.request_uid,
        category: t("contact_requests.categories.#{contact_request.category}")
      )
    )
  end

  private

  def masked_email(email)
    local, domain = email.to_s.split("@", 2)
    return "masked" if local.blank? || domain.blank?

    visible = local.first(2)
    "#{visible}***@#{domain}"
  end
end
