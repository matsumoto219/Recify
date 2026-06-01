module ExternalServices
  DebugSwitchNotAvailableError = Class.new(StandardError)

  class << self
    def services
      StatusStore::SERVICES
    end

    def state(service)
      StatusStore.state(service)
    end

    def snapshot(service)
      StatusStore.snapshot(service)
    end

    def snapshots
      services.index_with { |service| snapshot(service) }
    end

    def ok?(service)
      StatusStore.ok?(service)
    end

    def degraded?(service)
      StatusStore.degraded?(service)
    end

    def down?(service)
      StatusStore.down?(service)
    end

    def monitoring?(service)
      StatusStore.monitoring?(service)
    end

    def due_for_check?(service)
      StatusStore.due_for_check?(service)
    end

    def services_due_for_check
      StatusStore.services_due_for_check
    end

    def mark_success!(service)
      StatusStore.mark_success!(service)
    end

    def mark_failure!(service, error_code:, reason: nil)
      StatusStore.mark_failure!(service, error_code: error_code)
    end

    def mark_monitor_failure!(service, error_code:, reason: nil)
      StatusStore.mark_monitor_failure!(service, error_code: error_code)
    end

    def reset!(service = nil)
      return services.each { |service_name| StatusStore.reset!(service_name) } if service.nil?

      StatusStore.reset!(service)
    end

    def external_error?(error_or_code)
      error_code = error_or_code.respond_to?(:error_code) ? error_or_code.error_code : error_or_code

      StatusStore.external_error?(error_code)
    end

    def status_snapshot(...)
      StatusSnapshot.call(...)
    end

    def switch_debug_state(...)
      DebugStateSwitcher.call(...)
    rescue DebugStateSwitcher::NotAvailableError => e
      raise DebugSwitchNotAvailableError, e.message
    end

    def debug_switch_available?
      DebugStateSwitcher.available?
    end

    def check_available?(service)
      case normalize_service(service)
      when :ocr
        Ocr::AvailabilityChecker.call
      when :ai
        Ai::AvailabilityChecker.call
      end
    end

    private

    def normalize_service(service)
      normalized = service.to_s.strip.to_sym
      return normalized if StatusStore::SERVICES.include?(normalized)

      raise ArgumentError, "Unsupported service: #{service}"
    end
  end
end
