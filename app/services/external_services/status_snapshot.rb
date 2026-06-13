module ExternalServices
  class StatusSnapshot
    SERVICES = StatusStore::SERVICES.freeze

    class << self
      def call(renderer: nil)
        new(renderer: renderer).call
      end
    end

    def initialize(renderer: nil)
      @renderer = renderer
    end

    def call
      snapshots = ExternalServices.snapshots
      states = snapshots.transform_values { |snapshot| service_state(snapshot) }
      ocr_state = states.fetch(:ocr)
      ai_state = states.fetch(:ai)

      {
        ocr: service_payload(:ocr, snapshots.fetch(:ocr), ocr_state),
        ai: service_payload(:ai, snapshots.fetch(:ai), ai_state),
        upload: {
          allowed: ocr_state != "down",
          ocr_available: ocr_state != "down"
        },
        notices: {
          ocr_down: ocr_state == "down",
          ocr_degraded: ocr_state == "degraded",
          ai_down: ai_state == "down",
          ai_degraded: ai_state == "degraded"
        }
      }
    end

    private

    attr_reader :renderer

    def service_payload(service, snapshot, state)
      normalized = snapshot.with_indifferent_access

      {
        state: state,
        monitoring: normalized[:monitoring] == true,
        checked_at: normalized[:last_checked_at],
        last_checked_at: normalized[:last_checked_at],
        next_check_at: normalized[:next_check_at],
        last_error_code: normalized[:last_error_code],
        consecutive_failures: normalized[:consecutive_failures],
        consecutive_successes: normalized[:consecutive_successes],
        disabled: normalized[:disabled] == true,
        source: normalized[:source],
        reason: normalized[:reason],
        setting_key: normalized[:setting_key],
        env_key: normalized[:env_key],
        text: service_status_text(state),
        message: service_status_message(service, state),
        badge_html: service_status_badge_html(service, state)
      }
    end

    def service_state(snapshot)
      snapshot.with_indifferent_access[:state].presence || "ok"
    end

    def service_status_text(state)
      translate("shared.service_status.#{state}", default: translate("shared.service_status.unknown"))
    end

    def service_status_message(service, state)
      case [ service, state ]
      when [ :ocr, "down" ]
        translate("flash.receipts.ocr_unavailable")
      when [ :ocr, "degraded" ]
        translate("receipts.new_upload.ocr_degraded")
      when [ :ai, "down" ]
        translate("receipts.new_upload.ai_down")
      when [ :ai, "degraded" ]
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
