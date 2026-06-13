module ExternalServices
  class StatusStore
    STATES = %w[ok degraded down].freeze
    SERVICES = %i[ocr ai].freeze

    EXTERNAL_ERROR_CODES = %w[
      external_service_unavailable
      external_service_auth_error
      external_service_quota_exceeded
      external_service_rate_limited
      ocr_timeout
      ocr_api_error
      ai_auth_error
      ai_quota_exceeded
      ai_rate_limited
      ai_timeout
      ai_config_error
      ai_api_error
      ai_primary_failed
      ai_fallback_failed
    ].freeze

    FAILURE_WINDOW = 5.minutes
    DEGRADED_THRESHOLD = 2
    DOWN_THRESHOLD = 3
    RECOVERY_SUCCESS_THRESHOLD = 2

    class << self
      def mark_success!(service_name)
        service = normalize_service_name(service_name)
        data = read(service)

        data["consecutive_successes"] += 1
        data["consecutive_failures"] = 0
        data["first_failed_at"] = nil
        data["last_error_code"] = nil
        data["last_error_reason"] = nil
        data["last_error_detail"] = nil
        data["last_checked_at"] = current_time.iso8601

        if data["state"] == "down" && data["consecutive_successes"] >= RECOVERY_SUCCESS_THRESHOLD
          data["state"] = "ok"
          data["monitoring"] = false
          data["next_check_at"] = nil
        elsif data["state"] == "degraded" && data["consecutive_successes"] >= 1
          data["state"] = "ok"
          data["monitoring"] = false
          data["next_check_at"] = nil
        end

        write(service, data)
      end

      def mark_failure!(service_name, error_code:, reason: nil, detail: nil)
        return unless external_error?(error_code)

        service = normalize_service_name(service_name)
        data = read(service)
        now = current_time
        assign_error_data!(data, service:, error_code:, reason:, detail:, checked_at: now)

        reset_failure_window!(data, now)

        data["consecutive_successes"] = 0

        if data["state"] == "down"
          data["consecutive_failures"] = DOWN_THRESHOLD
          return write(service, data)
        end

        data["consecutive_failures"] = [ data["consecutive_failures"] + 1, DOWN_THRESHOLD ].min
        data["first_failed_at"] ||= now.iso8601

        if data["consecutive_failures"] >= DOWN_THRESHOLD
          data["state"] = "down"
          data["monitoring"] = true
          data["next_check_at"] = next_check_at_for(1, now).iso8601
        elsif data["consecutive_failures"] >= DEGRADED_THRESHOLD
          data["state"] = "degraded"
          data["monitoring"] = true
          data["next_check_at"] = next_check_at_for(0, now).iso8601
        end

        write(service, data)
      end

      def mark_monitor_failure!(service_name, error_code: "external_service_unavailable", reason: nil, detail: nil)
        return unless external_error?(error_code)

        service = normalize_service_name(service_name)
        data = read(service)
        now = current_time

        data["consecutive_successes"] = 0
        assign_error_data!(data, service:, error_code:, reason:, detail:, checked_at: now)

        return write(service, data) unless data["monitoring"] == true

        data["state"] = "degraded" unless data["state"] == "down"
        data["monitoring"] = true
        data["next_check_at"] = next_check_at_for(monitor_recovery_attempt_for(data), now).iso8601

        write(service, data)
      end

      def state(service_name)
        read(normalize_service_name(service_name))["state"]
      end

      def ok?(service_name)
        state(service_name) == "ok"
      end

      def degraded?(service_name)
        state(service_name) == "degraded"
      end

      def down?(service_name)
        state(service_name) == "down"
      end

      def monitoring?(service_name)
        read(normalize_service_name(service_name))["monitoring"] == true
      end

      def due_for_check?(service_name)
        data = read(normalize_service_name(service_name))
        return false unless data["monitoring"] == true

        next_check_at = parse_time(data["next_check_at"])
        next_check_at.present? && next_check_at <= current_time
      end

      def services_due_for_check
        SERVICES.select { |service| due_for_check?(service) }
      end

      def snapshot(service_name)
        read(normalize_service_name(service_name)).deep_symbolize_keys
      end

      def reset!(service_name)
        service = normalize_service_name(service_name)
        write(service, default_data)
      end

      def external_error?(error_code)
        EXTERNAL_ERROR_CODES.include?(error_code.to_s)
      end

      private

      def normalize_service_name(service_name)
        service = service_name.to_sym
        return service if SERVICES.include?(service)

        raise ArgumentError, "Unsupported service: #{service_name}"
      end

      def cache_key(service_name)
        "external_service_status:#{service_name}"
      end

      def read(service_name)
        raw = Rails.cache.read(cache_key(service_name))
        data = raw.is_a?(Hash) ? raw.deep_stringify_keys : default_data
        data.reverse_merge(default_data)
      end

      def write(service_name, data)
        normalized = data.deep_stringify_keys
        Rails.cache.write(cache_key(service_name), normalized)
        normalized
      end

      def default_data
        {
          "state" => "ok",
          "monitoring" => false,
          "consecutive_failures" => 0,
          "consecutive_successes" => 0,
          "first_failed_at" => nil,
          "last_error_code" => nil,
          "last_error_reason" => nil,
          "last_error_detail" => nil,
          "last_checked_at" => nil,
          "next_check_at" => nil
        }
      end

      def assign_error_data!(data, service:, error_code:, reason:, detail:, checked_at:)
        data["last_error_code"] = error_code
        data["last_error_reason"] = safe_reason(reason || error_code)
        data["last_error_detail"] = safe_error_detail(service, detail)
        data["last_checked_at"] = checked_at.iso8601
      end

      def safe_error_detail(service, detail)
        return nil unless detail.respond_to?(:to_h)

        normalized = detail.to_h.with_indifferent_access
        return nil if normalized.blank?

        ExternalServices.error_detail(
          service: normalized[:service] || service,
          provider: normalized[:provider],
          phase: normalized[:phase],
          http_status: normalized[:http_status],
          provider_error_code: normalized[:provider_error_code],
          provider_error_type: normalized[:provider_error_type],
          provider_message_safe: normalized[:provider_message_safe],
          request_id: normalized[:request_id],
          region: normalized[:region],
          retry_after: normalized[:retry_after],
          latency_ms: normalized[:latency_ms],
          poll_count: normalized[:poll_count],
          model: normalized[:model],
          rate_limited: normalized[:rate_limited],
          quota_exceeded: normalized[:quota_exceeded],
          auth_error: normalized[:auth_error],
          disabled: normalized[:disabled],
          source: normalized[:source],
          reason: normalized[:reason]
        ).presence
      end

      def safe_reason(value)
        value.to_s.presence&.truncate(100)
      end

      def reset_failure_window!(data, now)
        first_failed_at = parse_time(data["first_failed_at"])
        return if first_failed_at.present? && (now - first_failed_at) <= FAILURE_WINDOW

        data["consecutive_failures"] = 0
        data["first_failed_at"] = nil

        return unless data["state"] == "degraded"

        data["state"] = "ok"
        data["monitoring"] = false
        data["next_check_at"] = nil
      end

      def next_check_at_for(recovery_attempt, now)
        minutes = case recovery_attempt
        when 0 then 3
        when 1 then 5
        else 10
        end

        now + minutes.minutes
      end

      def monitor_recovery_attempt_for(data)
        return 0 unless data["state"] == "down"

        data["consecutive_successes"].to_i >= 1 ? 2 : 1
      end

      def parse_time(value)
        return nil if value.blank?

        Time.zone.parse(value)
      rescue ArgumentError, TypeError
        nil
      end

      def current_time
        Time.current
      end
    end
  end
end
