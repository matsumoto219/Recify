# frozen_string_literal: true

require "base64"
require "open3"
require "rails_helper"

RSpec.describe "Analysis run status sync Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/analysis_run_status_sync_controller.js").read }

  def run_controller_script(script)
    encoded_source = Base64.strict_encode64(source)
    harness = <<~JAVASCRIPT
      const source = Buffer.from(#{encoded_source.inspect}, 'base64').toString('utf8')
        .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
        .replace('export default class extends Controller', 'class AnalysisRunStatusSyncController extends Controller')

      eval(`${source}\nglobalThis.AnalysisRunStatusSyncController = AnalysisRunStatusSyncController`)
      #{script}
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", harness)
    raise stderr unless status.success?

    JSON.parse(stdout)
  end

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

  it "stops polling when authentication expires or the endpoint returns HTML" do
    aggregate_failures do
      expect(source).to include('response.redirected')
      expect(source).to include('response.status === 401')
      expect(source).to include('response.status === 403')
      expect(source).to include('response.status === 404')
      expect(source).to include("response.headers.get('content-type')")
      expect(source).to include('this.pausePolling()')
    end
  end

  it "refreshes the detail page once when an active run reaches a terminal state" do
    aggregate_failures do
      expect(source).to include("refreshOnTerminal: { type: Boolean, default: false }")
      expect(source).to include("if (state.terminal) this.queueTerminalRefresh()")
      expect(source).to include("Turbo.visit(window.location.href, { action: 'replace' })")
      expect(source).to include("this.clearTerminalRefreshTimer()")
    end
  end

  it "uses capped exponential backoff for temporary failures" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(AnalysisRunStatusSyncController.prototype)
      Object.defineProperties(controller, {
        slowIntervalValue: { value: 15000 },
        maxBackoffValue: { value: 60000 }
      })
      controller.consecutiveFailures = 0
      const delays = []
      for (let index = 0; index < 5; index += 1) {
        controller.registerTemporaryFailure()
        delays.push(controller.retryAfterMilliseconds)
      }
      process.stdout.write(JSON.stringify(delays))
    JAVASCRIPT

    expect(result).to eq([ 15000, 30000, 60000, 60000, 60000 ])
  end

  it "honors Retry-After without polling faster than the local backoff" do
    result = run_controller_script(<<~JAVASCRIPT)
      const controller = Object.create(AnalysisRunStatusSyncController.prototype)
      Object.defineProperties(controller, {
        slowIntervalValue: { value: 15000 },
        maxBackoffValue: { value: 60000 }
      })
      controller.consecutiveFailures = 0
      const response = { headers: { get: () => '45' } }
      controller.registerRateLimit(response)
      process.stdout.write(JSON.stringify(controller.retryAfterMilliseconds))
    JAVASCRIPT

    expect(result).to eq(45_000)
  end
end
