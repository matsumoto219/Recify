class ExternalServices::StatusPresenter
  SERVICES = %i[ocr ai].freeze

  class << self
    def call(snapshot:, view_context:, render_badges: true)
      new(snapshot: snapshot, view_context: view_context, render_badges: render_badges).call
    end
  end

  def initialize(snapshot:, view_context:, render_badges: true)
    @snapshot = snapshot.to_h.deep_dup.deep_symbolize_keys
    @view_context = view_context
    @render_badges = render_badges == true
  end

  def call
    ocr_available = snapshot.dig(:upload, :ocr_available) == true

    SERVICES.each do |service|
      payload = snapshot.fetch(service, {})
      state = payload[:state].presence || "ok"
      payload.merge!(
        text: service_status_text(state),
        message: service_status_message(service, state, ocr_available: ocr_available),
        badge_html: service_status_badge_html(service, state)
      )
      snapshot[service] = payload
    end

    snapshot
  end

  private

  attr_reader :snapshot, :view_context

  def render_badges?
    @render_badges
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
      translate("receipts.new_upload.ai_down") if ocr_available
    when [ :ai, "degraded" ]
      translate("receipts.new_upload.ai_degraded") if ocr_available
    end
  end

  def service_status_badge_html(service, state)
    return unless render_badges?

    view_context.render_to_string(
      partial: "shared/ui/badge/service_status_badge",
      formats: [ :html ],
      locals: {
        label: translate("settings.index.services.#{service}"),
        state: state.to_sym
      }
    )
  end

  def translate(key, **options)
    view_context.t(key, **options)
  end
end
