# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Receipt processing sync Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/receipt_processing_sync_controller.js").read }

  it "syncs only processing card targets with one batched request" do
    aggregate_failures do
      expect(source).to include("static targets = ['card']")
      expect(source).to include("url: String")
      expect(source).to include("interval: { type: Number, default: 3000 }")
      expect(source).to include("slowInterval: { type: Number, default: 10000 }")
      expect(source).to include("fastPollLimit: { type: Number, default: 10 }")
      expect(source).to include("this.cardTargets")
      expect(source).to include("url.searchParams.append('public_ids[]', publicId)")
      expect(source).to include("url.searchParams.append('state_revisions[]', stateRevision)")
      expect(source).to include("card.dataset.receiptCardStateRevision")
      expect(source).to include("Accept: 'text/vnd.turbo-stream.html'")
      expect(source).to include("Turbo.renderStreamMessage")
      expect(source).not_to include("setInterval")
      expect(source).to include("this.nextPollDelay()")
      expect(source).to include("if (this.syncInFlight) return")
    end
  end

  it "repairs missed updates after navigation, visibility recovery, and network recovery" do
    aggregate_failures do
      expect(source).to include("document.addEventListener('turbo:load', this.handleTurboLoad)")
      expect(source).to include("document.addEventListener('turbo:before-cache', this.handleBeforeCache)")
      expect(source).to include("document.addEventListener('visibilitychange', this.handleVisibilityChange)")
      expect(source).to include("window.addEventListener('online', this.handleOnline)")
      expect(source).to include("new window.MutationObserver(this.handleCableMutations)")
      expect(source).to include("'turbo-cable-stream-source[connected]'")
      expect(source).to include("this.cableObserver?.disconnect()")
      expect(source).to include("document.visibilityState === 'hidden'")
      expect(source).to include("this.queueImmediateSync()")
      expect(source).to include("this.stopPolling({ abort: true })")
      expect(source).to include("this.pollingPaused = true")
      expect(source).to include("this.pollingPaused = false")
    end
  end

  it "backs off after throttling or a temporary sync failure" do
    aggregate_failures do
      expect(source).to include("response.status === 429")
      expect(source).to include("response.headers.get('Retry-After')")
      expect(source).to include("this.retryAfterMilliseconds = this.slowIntervalValue")
      expect(source).to include("Math.max(retryAfterSeconds * 1000, this.slowIntervalValue)")
    end
  end

  it "rejects older receipt card streams before Turbo renders them" do
    aggregate_failures do
      expect(source).to include("document.addEventListener('turbo:before-stream-render', this.handleBeforeStreamRender)")
      expect(source).to include("incomingRevision < currentRevision")
      expect(source).to include("incomingPhaseOrder < currentPhaseOrder")
      expect(source).to include("event.preventDefault()")
      expect(source).to include("receiptCardTerminal")
    end
  end

  it "refreshes scoped or sorted results only when a terminal card arrives" do
    aggregate_failures do
      expect(source).to include("refreshOnTerminal: { type: Boolean, default: false }")
      expect(source).to include("incomingCard.dataset.receiptCardTerminal !== 'true'")
      expect(source).to include("this.queueIndexRefresh()")
      expect(source).to include("Turbo.visit(window.location.href, { action: 'replace' })")
    end
  end
end
