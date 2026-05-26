module ExternalServices
  DebugSwitchNotAvailableError = Class.new(StandardError)

  class << self
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
      return normalized if ExternalServiceStatus::SERVICES.include?(normalized)

      raise ArgumentError, "Unsupported service: #{service}"
    end
  end
end
