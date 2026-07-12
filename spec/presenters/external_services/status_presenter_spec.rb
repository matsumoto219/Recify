require "rails_helper"

RSpec.describe ExternalServices::StatusPresenter do
  let(:view_context) { double("view context") }

  before do
    allow(view_context).to receive(:t) { |key, **options| I18n.t(key, **options) }
    allow(view_context).to receive(:render_to_string) do |partial:, formats:, locals:|
      "#{partial}:#{formats.join(',')}:#{locals[:label]}:#{locals[:state]}"
    end
  end

  it "表示文言とbadge HTMLをraw snapshotへ追加し、入力を変更しない" do
    raw_snapshot = {
      ocr: { state: "ok", monitoring: false },
      ai: { state: "down", monitoring: true },
      upload: { allowed: true, ocr_available: true },
      notices: { ai_down: true }
    }
    original = raw_snapshot.deep_dup

    payload = described_class.call(snapshot: raw_snapshot, view_context: view_context, render_badges: true)

    aggregate_failures do
      expect(raw_snapshot).to eq(original)
      expect(payload.dig(:ocr, :text)).to eq(I18n.t("shared.service_status.ok"))
      expect(payload.dig(:ocr, :message)).to be_nil
      expect(payload.dig(:ai, :text)).to eq(I18n.t("shared.service_status.down"))
      expect(payload.dig(:ai, :message)).to eq(I18n.t("receipts.new_upload.ai_down"))
      expect(payload.dig(:ocr, :badge_html)).to include("external_services/status_badge")
      expect(payload.dig(:ai, :badge_html)).to include("external_services/status_badge")
      expect(view_context).to have_received(:render_to_string).with(
        partial: "external_services/status_badge",
        formats: [ :html ],
        locals: {
          label: I18n.t("settings.index.services.ocr"),
          state: :ok
        }
      )
    end
  end

  it "OCR停止中はAI noticeを抑制し、badge無効時はHTMLを生成しない" do
    payload = described_class.call(
      snapshot: {
        ocr: { state: "down", provider_message_safe: "safe detail" },
        ai: { state: "degraded" },
        upload: { allowed: false, ocr_available: false },
        notices: { ocr_down: true, ai_degraded: false }
      },
      view_context: view_context,
      render_badges: false
    )

    aggregate_failures do
      expect(payload.dig(:ocr, :message)).to eq(I18n.t("flash.receipts.ocr_unavailable"))
      expect(payload.dig(:ai, :message)).to be_nil
      expect(payload.dig(:ocr, :badge_html)).to be_nil
      expect(payload.dig(:ocr, :provider_message_safe)).to eq("safe detail")
      expect(view_context).not_to have_received(:render_to_string)
    end
  end

  it "string keyのsnapshotも同じsymbol key payloadへ正規化する" do
    payload = described_class.call(
      snapshot: {
        "ocr" => { "state" => "degraded" },
        "ai" => { "state" => "ok" },
        "upload" => { "allowed" => true, "ocr_available" => true }
      },
      view_context: view_context,
      render_badges: false
    )

    aggregate_failures do
      expect(payload.dig(:ocr, :text)).to eq(I18n.t("shared.service_status.degraded"))
      expect(payload.dig(:ocr, :message)).to eq(I18n.t("receipts.new_upload.ocr_degraded"))
      expect(payload.dig(:upload, :allowed)).to eq(true)
    end
  end
end
