module ExternalServices
  class StatusSnapshot
    SERVICES = StatusStore::SERVICES.freeze

    class << self
      def call(include_details: false)
        new(include_details: include_details).call
      end
    end

    def initialize(include_details: false)
      @include_details = include_details == true
    end

    def call
      snapshots = ExternalServices.snapshots
      states = snapshots.transform_values { |snapshot| service_state(snapshot) }
      ocr_state = states.fetch(:ocr)
      ai_state = states.fetch(:ai)
      ocr_available = ocr_state != "down"

      {
        ocr: service_payload(snapshots.fetch(:ocr), ocr_state),
        ai: service_payload(snapshots.fetch(:ai), ai_state),
        upload: {
          allowed: ocr_available,
          ocr_available: ocr_available
        },
        notices: {
          ocr_down: ocr_state == "down",
          ocr_degraded: ocr_state == "degraded",
          ai_down: ocr_available && ai_state == "down",
          ai_degraded: ocr_available && ai_state == "degraded"
        }
      }
    end

    private

    def include_details?
      @include_details
    end

    def service_payload(snapshot, state)
      normalized = snapshot.with_indifferent_access
      detail = normalized_hash(normalized[:last_error_detail])

      payload = {
        state: state,
        monitoring: normalized[:monitoring] == true,
        checked_at: normalized[:last_checked_at],
        last_checked_at: normalized[:last_checked_at],
        next_check_at: normalized[:next_check_at],
        consecutive_failures: normalized[:consecutive_failures],
        consecutive_successes: normalized[:consecutive_successes],
        disabled: normalized[:disabled] == true
      }

      include_details? ? payload.merge(detail_payload(normalized, detail)) : payload
    end

    def detail_payload(normalized, detail)
      {
        source: normalized[:source],
        reason: normalized[:reason],
        setting_key: normalized[:setting_key],
        env_key: normalized[:env_key],
        last_error_code: normalized[:last_error_code],
        last_error_reason: normalized[:last_error_reason],
        last_error_detail: detail.presence,
        http_status: detail[:http_status],
        retry_after: detail[:retry_after],
        retry_after_at: detail[:retry_after_at],
        request_id: detail[:request_id],
        region: detail[:region],
        policy_id: detail[:policy_id],
        provider_error_code: detail[:provider_error_code],
        provider_error_type: detail[:provider_error_type],
        provider_message_safe: detail[:provider_message_safe],
        quota_exceeded: detail[:quota_exceeded],
        rate_limited: detail[:rate_limited],
        auth_error: detail[:auth_error]
      }
    end

    def service_state(snapshot)
      snapshot.with_indifferent_access[:state].presence || "ok"
    end

    def normalized_hash(value)
      return value.with_indifferent_access if value.respond_to?(:with_indifferent_access)

      {}
    end
  end
end
