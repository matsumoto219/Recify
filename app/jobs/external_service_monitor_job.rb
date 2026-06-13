class ExternalServiceMonitorJob < ApplicationJob
  queue_as :default

  DEFAULT_ERROR_CODES = {
    ocr: "external_service_unavailable",
    ai: "ai_api_error"
  }.freeze
  STATIC_AVAILABILITY_SERVICES = %i[ocr].freeze

  def perform
    ExternalServices.services_due_for_check.each do |service|
      monitor_service(service)
    end
  end

  private

  def monitor_service(service)
    if ExternalServices.check_available?(service)
      if static_availability_service?(service)
        keep_monitoring_until_real_success(service)
      else
        ExternalServices.mark_success!(service)
      end
    else
      ExternalServices.mark_monitor_failure!(service, error_code: DEFAULT_ERROR_CODES.fetch(service))
    end
  rescue StandardError => e
    Rails.logger.warn(
      "[ExternalServiceMonitorJob] service=#{service} failed class=#{e.class} message=#{e.message}"
    )
    ExternalServices.mark_monitor_failure!(service, error_code: DEFAULT_ERROR_CODES.fetch(service))
  end

  def static_availability_service?(service)
    STATIC_AVAILABILITY_SERVICES.include?(service.to_sym)
  end

  def keep_monitoring_until_real_success(service)
    snapshot = ExternalServices.snapshot(service)
    ExternalServices.mark_monitor_failure!(
      service,
      error_code: snapshot[:last_error_code].presence || DEFAULT_ERROR_CODES.fetch(service),
      reason: snapshot[:last_error_reason],
      detail: snapshot[:last_error_detail]
    )
  end
end
