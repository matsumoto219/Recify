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
    @created_at = contact_request.created_at.present? ? I18n.l(contact_request.created_at, format: :long) : "-"
    @masked_email = masked_email(contact_request.email)
    @request_id = contact_request.request_id.presence || "-"
    @source_label = source_label(contact_request.source)

    mail(
      to: self.class.notification_email,
      subject: t(
        "contact_requests.mailer.admin_notification.subject",
        request_uid: contact_request.request_uid,
        category: t("contact_requests.categories.#{contact_request.category}")
      )
    )
  end

  def auto_reply(contact_request)
    @contact_request = contact_request
    @recipient_name = contact_request_recipient_name(contact_request)
    @created_at = contact_request.created_at.present? ? I18n.l(contact_request.created_at, format: :long) : "-"

    mail(
      to: contact_request.email,
      subject: t(
        "contact_requests.mailer.auto_reply.subject",
        request_uid: contact_request.request_uid
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

  def source_label(source)
    return "-" if source.blank?

    t("contact_requests.sources.#{source}", default: source)
  end
end
