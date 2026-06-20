class ApplicationMailer < ActionMailer::Base
  default from: ENV["SMTP_FROM"].presence || "from@example.com"
  layout "mailer"

  helper_method :mailer_duration_text,
                :contact_request_recipient_name,
                :devise_recipient_name

  private

  def contact_request_recipient_name(contact_request)
    contact_request.sender_name.presence ||
      contact_request.user&.name.to_s.strip.presence ||
      contact_request.email.to_s
  end

  def devise_recipient_name(resource, delivery_email:)
    resource&.name.to_s.strip.presence || delivery_email.to_s
  end

  def mailer_duration_text(duration)
    seconds = duration.to_i if duration.respond_to?(:to_i)
    return if seconds.blank? || seconds <= 0

    unit, divisor = {
      days: 1.day.to_i,
      hours: 1.hour.to_i,
      minutes: 1.minute.to_i
    }.find { |_key, value| seconds >= value && (seconds % value).zero? } || [ :seconds, 1 ]

    t("auth.mailer.common.duration.#{unit}", count: seconds / divisor)
  end
end
