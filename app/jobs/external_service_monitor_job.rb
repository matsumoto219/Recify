class ExternalServiceMonitorJob < ApplicationJob
  queue_as :default

  CHECKERS = {
    ocr: Ocr::AvailabilityChecker,
    ai: Ai::AvailabilityChecker
  }.freeze

  DEFAULT_ERROR_CODES = {
    ocr: "external_service_unavailable",
    ai: "ai_api_error"
  }.freeze

  def perform
    ExternalServiceStatus.services_due_for_check.each do |service|
      monitor_service(service)
    end
  end

  private

  def monitor_service(service)
    if CHECKERS.fetch(service).call
      ExternalServiceStatus.mark_success!(service)
    else
      ExternalServiceStatus.mark_monitor_failure!(service, error_code: DEFAULT_ERROR_CODES.fetch(service))
    end
  rescue StandardError => e
    Rails.logger.warn(
      "[ExternalServiceMonitorJob] service=#{service} failed class=#{e.class} message=#{e.message}"
    )
    ExternalServiceStatus.mark_monitor_failure!(service, error_code: DEFAULT_ERROR_CODES.fetch(service))
  end
end
