class ApplicationMailer < ActionMailer::Base
  default from: "from@example.com"
  layout "mailer"

  helper_method :mailer_duration_text

  private

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
