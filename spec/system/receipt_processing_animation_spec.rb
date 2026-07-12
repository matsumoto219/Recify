# frozen_string_literal: true

require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "レシート処理進捗animationの実Chrome回帰", type: :system, mobile: true do
  before do
    set_viewport(width: 390, height: 844)
  end

  after do
    page.execute_script("window.__receiptProcessingGlintProbe?.cleanup?.()")
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  def set_viewport(width:, height:)
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width:,
      height:,
      deviceScaleFactor: 1,
      mobile: true
    )
  end

  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  def create_ocr_fixture(user)
    receipt = create(:receipt, :processing, :with_image, user:, store_name: "Animation確認")
    run = create(
      :receipt_analysis_run,
      receipt:,
      status: "running",
      stage: "ocr",
      ocr_started_at: Time.current
    )

    [ receipt, run ]
  end

  def force_processing_card_sync
    result = page.evaluate_async_script(<<~JAVASCRIPT, Capybara.default_max_wait_time * 1000)
      const timeoutMilliseconds = arguments[0]
      const done = arguments[arguments.length - 1]
      const deadline = window.performance.now() + timeoutMilliseconds

      const syncWhenIdle = () => {
        const controller = window.Stimulus?.controllers?.find((candidate) => {
          return candidate.identifier === 'receipt-processing-sync' &&
            candidate.element.id === 'receipts-results'
        })
        if (controller && !controller.syncInFlight) {
          controller.clearPollTimer()
          const completedBefore = controller.completedPollCount
          controller.syncNow().then(() => done(controller.completedPollCount > completedBefore))
          return
        }
        if (window.performance.now() >= deadline) {
          done(false)
          return
        }

        window.setTimeout(syncWhenIdle, 25)
      }

      syncWhenIdle()
    JAVASCRIPT

    expect(result).to be(true)
  end

  def install_animation_probe(panel_id, card_id, expected_iterations: 10)
    page.execute_script(<<~JAVASCRIPT, panel_id, card_id, expected_iterations)
      (() => {
        const panel = document.getElementById(arguments[0])
        const active = panel.querySelector('.receipt-processing-interval-active')
        const animationName = window.getComputedStyle(active, '::before').animationName
        const card = document.getElementById(arguments[1])
        const expectedIterations = arguments[2]
        const events = { starts: [], iterations: [], cancels: [] }
        const streamTargets = []

        const animationHandler = (event) => {
          if (event.animationName !== animationName || event.pseudoElement !== '::before') return

          const entry = {
            elapsedTime: event.elapsedTime,
            opacity: Number(window.getComputedStyle(event.target, '::before').opacity),
            targetMatches: event.target === active,
            time: window.performance.now()
          }
          if (event.type === 'animationstart') {
            events.starts.push(entry)
            document.documentElement.dataset.glintProbeStarts = String(events.starts.length)
          }
          if (event.type === 'animationiteration') {
            events.iterations.push(entry)
            if (events.iterations.length >= expectedIterations) {
              document.documentElement.dataset.glintProbeComplete = String(expectedIterations)
            }
          }
          if (event.type === 'animationcancel') events.cancels.push(entry)
        }
        const streamHandler = (event) => {
          streamTargets.push(event.target?.getAttribute?.('target'))
        }

        document.addEventListener('animationstart', animationHandler)
        document.addEventListener('animationiteration', animationHandler)
        document.addEventListener('animationcancel', animationHandler)
        document.addEventListener('turbo:before-stream-render', streamHandler)

        window.__receiptProcessingGlintProbe = {
          active,
          animationHandler,
          animationName,
          card,
          events,
          observer: null,
          replacementCount: 0,
          sampleTimer: null,
          samples: [],
          streamHandler,
          streamTargets,
          startSampling() {
            this.observer = new window.MutationObserver((mutations) => {
              mutations.forEach((mutation) => {
                const removed = Array.from(mutation.removedNodes)
                if (removed.some((node) => node === this.active || node.contains?.(this.active))) {
                  this.replacementCount += 1
                }
              })
            })
            this.observer.observe(document.body, { childList: true, subtree: true })
            this.sampleTimer = window.setInterval(() => {
              const style = window.getComputedStyle(this.active, '::before')
              const match = style.backgroundPosition.match(/(-?[0-9.]+)%/)
              this.samples.push({
                opacity: Number(style.opacity),
                position: match ? Number(match[1]) : null,
                time: window.performance.now()
              })
            }, 40)
          },
          stopSampling() {
            window.clearInterval(this.sampleTimer)
            this.sampleTimer = null
            this.observer?.disconnect()
            this.observer = null
          },
          cleanup() {
            this.stopSampling()
            delete document.documentElement.dataset.glintProbeComplete
            delete document.documentElement.dataset.glintProbeStarts
            document.removeEventListener('animationstart', this.animationHandler)
            document.removeEventListener('animationiteration', this.animationHandler)
            document.removeEventListener('animationcancel', this.animationHandler)
            document.removeEventListener('turbo:before-stream-render', this.streamHandler)
          }
        }
      })()
    JAVASCRIPT
  end

  def wait_for_animation_iterations(count)
    expect(page).to have_css("html[data-glint-probe-complete='#{count}']", wait: 30)
  end

  def animation_probe_snapshot(panel_id, card_id)
    page.evaluate_script(<<~JAVASCRIPT, panel_id, card_id)
      (() => {
        const probe = window.__receiptProcessingGlintProbe
        const currentActive = document.getElementById(arguments[0])
          ?.querySelector('.receipt-processing-interval-active')
        const positions = probe.samples.map((sample) => sample.position)
        const resetIndexes = []
        for (let index = 1; index < positions.length; index += 1) {
          if (positions[index] !== null && positions[index - 1] !== null && positions[index] - positions[index - 1] > 50) {
            resetIndexes.push(index)
          }
        }
        const visibleResets = resetIndexes.filter((index) => {
          return probe.samples[index - 1].opacity > 0.1 && probe.samples[index].opacity > 0.1
        })
        const style = window.getComputedStyle(probe.active, '::before')
        return {
          animationCount: style.animationName.split(',').filter(Boolean).length,
          animationDelay: style.animationDelay,
          animationDirection: style.animationDirection,
          animationFillMode: style.animationFillMode,
          animationIterationCount: style.animationIterationCount,
          animationName: style.animationName,
          animationPlayState: style.animationPlayState,
          backgroundRepeat: style.backgroundRepeat,
          cancelCount: probe.events.cancels.length,
          cardIdentityMaintained: document.getElementById(arguments[1]) === probe.card,
          elementIdentityMaintained: currentActive === probe.active,
          iterationCount: probe.events.iterations.length,
          iterationResetOpacities: probe.events.iterations.map((event) => event.opacity),
          replacementCount: probe.replacementCount,
          resetCount: resetIndexes.length,
          startCount: probe.events.starts.length,
          streamTargets: probe.streamTargets,
          visibleResetCount: visibleResets.length
        }
      })()
    JAVASCRIPT
  end

  it "10周期のno-op pollingでDOMを維持し、見える位置でanimationをresetしない" do
    user = create_system_test_user
    receipt, run = create_ocr_fixture(user)
    card_selector = "##{receipt.dom_target_id}"

    sign_in_through_browser(user)
    wait_for_stimulus_controller("receipt-processing-sync")
    trigger = find("#{card_selector} .receipt-processing-trigger")
    panel_id = trigger["aria-controls"]
    install_animation_probe(panel_id, receipt.dom_target_id)

    trigger.click
    expect(page).to have_css("##{panel_id}.is-open")
    page.execute_script("window.__receiptProcessingGlintProbe.startSampling()")
    3.times { force_processing_card_sync }
    page.execute_script(<<~JAVASCRIPT)
      (() => {
        const active = window.__receiptProcessingGlintProbe.active
        active.classList.add('receipt-processing-interval-active')
        active.className = active.className
      })()
    JAVASCRIPT
    wait_for_animation_iterations(10)
    page.execute_script("window.__receiptProcessingGlintProbe.stopSampling()")

    snapshot = animation_probe_snapshot(panel_id, receipt.dom_target_id)
    aggregate_failures do
      expect(page.evaluate_script("window.innerWidth")).to eq(390)
      expect(snapshot.fetch("animationName")).to eq("receipt-processing-interval-flow")
      expect(snapshot.fetch("animationCount")).to eq(1)
      expect(snapshot.fetch("backgroundRepeat")).to eq("no-repeat")
      expect(snapshot.fetch("animationDelay")).to eq("0s")
      expect(snapshot.fetch("animationDirection")).to eq("normal")
      expect(snapshot.fetch("animationFillMode")).to eq("none")
      expect(snapshot.fetch("animationIterationCount")).to eq("infinite")
      expect(snapshot.fetch("animationPlayState")).to eq("running")
      expect(snapshot.fetch("startCount")).to eq(1)
      expect(snapshot.fetch("iterationCount")).to be >= 10
      expect(snapshot.fetch("iterationResetOpacities")).to all(be <= 0.05)
      expect(snapshot.fetch("cancelCount")).to eq(0)
      expect(snapshot.fetch("elementIdentityMaintained")).to be(true)
      expect(snapshot.fetch("cardIdentityMaintained")).to be(true)
      expect(snapshot.fetch("replacementCount")).to eq(0)
      expect(snapshot.fetch("streamTargets")).to be_empty
      expect(snapshot.fetch("resetCount")).to be >= 9
      expect(snapshot.fetch("visibleResetCount")).to eq(0)
    end

    page.execute_script("window.__receiptProcessingGlintProbe.cleanup()")
    trigger.click
    expect(page).to have_css("##{panel_id}[hidden]", visible: :all)
    set_viewport(width: 375, height: 812)
    page.refresh
    wait_for_stimulus_controller("receipt-processing-sync")

    vertical_trigger = find("#{card_selector} .receipt-processing-trigger")
    vertical_panel_id = vertical_trigger["aria-controls"]
    install_animation_probe(vertical_panel_id, receipt.dom_target_id)
    vertical_trigger.click
    expect(page).to have_css("##{vertical_panel_id}.is-open")
    page.execute_script("window.__receiptProcessingGlintProbe.startSampling()")
    wait_for_animation_iterations(10)
    page.execute_script("window.__receiptProcessingGlintProbe.stopSampling()")
    vertical_snapshot = animation_probe_snapshot(vertical_panel_id, receipt.dom_target_id)

    aggregate_failures do
      expect(page.evaluate_script("window.innerWidth")).to eq(375)
      expect(vertical_snapshot.fetch("animationName")).to eq("receipt-processing-interval-flow-vertical")
      expect(vertical_snapshot.fetch("backgroundRepeat")).to eq("no-repeat")
      expect(vertical_snapshot.fetch("startCount")).to eq(1)
      expect(vertical_snapshot.fetch("iterationCount")).to be >= 10
      expect(vertical_snapshot.fetch("cancelCount")).to eq(0)
      expect(vertical_snapshot.fetch("elementIdentityMaintained")).to be(true)
      expect(vertical_snapshot.fetch("visibleResetCount")).to eq(0)
    end

    starts_before_stage_change = vertical_snapshot.fetch("startCount")
    changed_at = [ Time.current, run.updated_at, receipt.updated_at ].max + 2.seconds
    run.update_columns(
      stage: "ai",
      ocr_finished_at: changed_at,
      ai_started_at: changed_at,
      updated_at: changed_at
    )
    force_processing_card_sync

    expect(page).to have_css("#{card_selector}[data-receipt-card-phase='ai']")
    expect(page).to have_css(
      "html[data-glint-probe-starts='#{starts_before_stage_change + 1}']",
      wait: Capybara.default_max_wait_time
    )

    terminal_at = changed_at + 2.seconds
    run.update_columns(status: "succeeded", stage: "completed", finalized_at: terminal_at, updated_at: terminal_at)
    receipt.update_columns(status: "completed", updated_at: terminal_at)
    force_processing_card_sync

    aggregate_failures do
      expect(page).to have_css("#{card_selector}[data-receipt-card-terminal='true']")
      expect(page).to have_no_css("#{card_selector} .receipt-processing-interval-active")
    end
    expect_browser_console_clean
  end
end
