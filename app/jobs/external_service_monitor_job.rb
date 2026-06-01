class ExternalServiceMonitorJob < ApplicationJob
  queue_as :default

  DEFAULT_ERROR_CODES = {
    ocr: "external_service_unavailable",
    ai: "ai_api_error"
  }.freeze

  def perform
    ExternalServices.services_due_for_check.each do |service|
      monitor_service(service)
    end
  end

  private

  def monitor_service(service)
    if ExternalServices.check_available?(service)
      ExternalServices.mark_success!(service)
    else
      ExternalServices.mark_monitor_failure!(service, error_code: DEFAULT_ERROR_CODES.fetch(service))
    end
  rescue StandardError => e
    Rails.logger.warn(
      "[ExternalServiceMonitorJob] service=#{service} failed class=#{e.class} message=#{e.message}"
    )
    ExternalServices.mark_monitor_failure!(service, error_code: DEFAULT_ERROR_CODES.fetch(service))
  end
end
