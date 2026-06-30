module ExternalServices
  class StatusSnapshot
    SERVICES = StatusStore::SERVICES.freeze

    class << self
      def call(renderer: nil, include_details: false)
        new(renderer: renderer, include_details: include_details).call
      end
    end

    def initialize(renderer: nil, include_details: false)
      @renderer = renderer
      @include_details = include_details == true
    end

    def call
      snapshots = ExternalServices.snapshots
      states = snapshots.transform_values { |snapshot| service_state(snapshot) }
      ocr_state = states.fetch(:ocr)
      ai_state = states.fetch(:ai)
      ocr_available = ocr_state != "down"

      {
        ocr: service_payload(:ocr, snapshots.fetch(:ocr), ocr_state, ocr_available: ocr_available),
        ai: service_payload(:ai, snapshots.fetch(:ai), ai_state, ocr_available: ocr_available),
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

    attr_reader :renderer

    def include_details?
      @include_details
    end

    def service_payload(service, snapshot, state, ocr_available: true)
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
        disabled: normalized[:disabled] == true,
        text: service_status_text(state),
        message: service_status_message(service, state, ocr_available: ocr_available),
        badge_html: service_status_badge_html(service, state)
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

    def service_status_text(state)
      translate("shared.service_status.#{state}", default: translate("shared.service_status.unknown"))
    end

    def service_status_message(service, state, ocr_available: true)
      case [ service, state ]
      when [ :ocr, "down" ]
        translate("flash.receipts.ocr_unavailable")
      when [ :ocr, "degraded" ]
        translate("receipts.new_upload.ocr_degraded")
      when [ :ai, "down" ]
        return unless ocr_available

        translate("receipts.new_upload.ai_down")
      when [ :ai, "degraded" ]
        return unless ocr_available

        translate("receipts.new_upload.ai_degraded")
      end
    end

    def service_status_badge_html(service, state)
      return unless renderer

      renderer.render_to_string(
        partial: "shared/ui/badge/service_status_badge",
        formats: [ :html ],
        locals: {
          label: translate("settings.index.services.#{service}"),
          state: state.to_sym
        }
      )
    end

    def translate(key, **options)
      return renderer.t(key, **options) if renderer

      I18n.t(key, **options)
    end
  end
end
