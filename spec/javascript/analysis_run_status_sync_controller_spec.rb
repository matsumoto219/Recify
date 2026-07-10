# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Analysis run status sync Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/analysis_run_status_sync_controller.js").read }

  it "polls only non-terminal rows with one batched admin request" do
    aggregate_failures do
      expect(source).to include("static targets = ['row']")
      expect(source).to include("interval: { type: Number, default: 5000 }")
      expect(source).to include("row.dataset.analysisRunStatusSyncTerminal !== 'true'")
      expect(source).to include("url.searchParams.append('run_keys[]'")
      expect(source).not_to include("setInterval")
    end
  end

  it "pauses while hidden and stops after terminal state" do
    aggregate_failures do
      expect(source).to include("document.addEventListener('visibilitychange'")
      expect(source).to include("document.visibilityState === 'hidden'")
      expect(source).to include("row.removeAttribute('data-analysis-run-status-sync-target')")
      expect(source).to include("if (this.activeRows().length === 0) return")
    end
  end

  it "updates text only and ignores an older state revision" do
    aggregate_failures do
      expect(source).to include("element.textContent = value")
      expect(source).not_to include("innerHTML")
      expect(source).to include("incomingRevision < currentRevision")
      expect(source).to include("cache: 'no-store'")
    end
  end
end
