class ExternalServicesController < ApplicationController
  before_action :authenticate_user!

  def status
    ocr_snapshot = ExternalServiceStatus.snapshot(:ocr)
    ai_snapshot = ExternalServiceStatus.snapshot(:ai)
    ocr_state = service_state(ocr_snapshot)
    ai_state = service_state(ai_snapshot)

    render json: {
      ocr: service_payload(:ocr, ocr_snapshot),
      ai: service_payload(:ai, ai_snapshot),
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

  def service_payload(service, snapshot)
    state = service_state(snapshot)

    {
      state: state,
      monitoring: snapshot.with_indifferent_access[:monitoring] == true,
      next_check_at: snapshot.with_indifferent_access[:next_check_at],
      text: service_status_text(state),
      message: service_status_message(service, state),
      badge_html: service_status_badge_html(service, state)
    }
  end

  def service_state(snapshot)
    snapshot.with_indifferent_access[:state].presence || "ok"
  end

  def service_status_text(state)
    case state
    when "ok" then t("shared.service_status.ok")
    when "degraded" then t("shared.service_status.degraded")
    when "down" then t("shared.service_status.down")
    else t("shared.service_status.unknown")
    end
  end

  def service_status_message(service, state)
    case [ service, state ]
    when [ :ocr, "down" ]
      t("flash.receipts.ocr_unavailable")
    when [ :ocr, "degraded" ]
      t("receipts.new_upload.ocr_degraded")
    when [ :ai, "down" ]
      t("receipts.new_upload.ai_down")
    when [ :ai, "degraded" ]
      t("receipts.new_upload.ai_degraded")
    end
  end

  def service_status_badge_html(service, state)
    render_to_string(
      partial: "shared/ui/service_status_badge",
      formats: [ :html ],
      locals: {
        label: t("settings.index.services.#{service}"),
        state: state.to_sym
      }
    )
  end
end
