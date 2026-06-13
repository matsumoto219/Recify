module ExternalServices
  DebugSwitchNotAvailableError = Class.new(StandardError)

  class << self
    def services
      StatusStore::SERVICES
    end

    def state(service)
      snapshot(service)[:state]
    end

    def snapshot(service)
      build_snapshot(normalize_service(service))
    end

    def snapshots
      services.index_with { |service| snapshot(service) }
    end

    def ok?(service)
      state(service) == "ok"
    end

    def degraded?(service)
      state(service) == "degraded"
    end

    def down?(service)
      state(service) == "down"
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

    def error_detail(...)
      ErrorDetail.build(...)
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
      normalized = normalize_service(service)
      return false unless enabled?(normalized)

      case normalized
      when :ocr
        ReceiptOcrService.available?
      when :ai
        ReceiptAiEnrichmentService.available?
      end
    end

    private

    def build_snapshot(service)
      snapshot = StatusStore.snapshot(service).with_indifferent_access
      operation = operation_status(service)

      if operation[:disabled]
        snapshot.merge(
          state: "down",
          disabled: true,
          source: operation[:source],
          reason: operation[:reason],
          setting_key: operation[:setting_key],
          env_key: operation[:env_key]
        ).deep_symbolize_keys
      else
        snapshot.merge(
          disabled: false,
          source: "status_store",
          reason: snapshot[:last_error_code]
        ).deep_symbolize_keys
      end
    end

    def enabled?(service)
      !operation_status(service)[:disabled]
    end

    def operation_status(service)
      setting_key = operation_setting_key(service)
      env_key = operation_env_key(service)

      return disabled_status(source: "system_setting", reason: setting_key, setting_key: setting_key, env_key: env_key) unless setting_enabled?(setting_key)
      return disabled_status(source: "env", reason: env_key, setting_key: setting_key, env_key: env_key) unless env_enabled?(env_key)

      { disabled: false, source: "status_store", reason: nil, setting_key: setting_key, env_key: env_key }
    end

    def disabled_status(source:, reason:, setting_key:, env_key:)
      {
        disabled: true,
        source: source,
        reason: reason,
        setting_key: setting_key,
        env_key: env_key
      }
    end

    def operation_setting_key(service)
      case service
      when :ocr
        "operations.ocr_enabled"
      when :ai
        "operations.ai_enabled"
      end
    end

    def operation_env_key(service)
      case service
      when :ocr
        ReceiptAnalysisPipeline::Config::OCR_ENABLED_ENV_KEY
      when :ai
        ReceiptAnalysisPipeline::Config::AI_ENABLED_ENV_KEY
      end
    end

    def setting_enabled?(key)
      SystemSettings.enabled?(key)
    rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
      true
    end

    def env_enabled?(key)
      ActiveModel::Type::Boolean.new.cast(ENV.fetch(key, "true"))
    end

    def normalize_service(service)
      normalized = service.to_s.strip.to_sym
      return normalized if StatusStore::SERVICES.include?(normalized)

      raise ArgumentError, "Unsupported service: #{service}"
    end
  end
end
