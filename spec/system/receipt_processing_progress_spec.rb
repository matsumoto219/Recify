require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "レシート処理進捗の実Chrome表示", type: :system, mobile: true do
  before do
    set_viewport(width: 390, height: 844)
  end

  after do
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
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

  def create_processing_fixture(user:, phase:)
    receipt = create(:receipt, :processing, :with_image, user:, store_name: "進捗#{phase}")
    now = Time.current
    attributes = case phase
    when :processing
      return [ receipt, nil ]
    when :queued
      { status: "queued", stage: "queued" }
    when :ocr
      { status: "running", stage: "ocr", ocr_started_at: now }
    when :organizing
      {
        status: "running",
        stage: "ocr_validation",
        ocr_started_at: now - 2.seconds,
        ocr_finished_at: now
      }
    when :ai
      {
        status: "running",
        stage: "ai",
        ocr_finished_at: now - 2.seconds,
        ai_started_at: now
      }
    when :finalize
      {
        status: "running",
        stage: "finalize",
        ocr_finished_at: now - 3.seconds,
        ai_started_at: now - 2.seconds,
        ai_finished_at: now - 1.second
      }
    else
      raise ArgumentError, "unknown phase: #{phase}"
    end

    [ receipt, create(:receipt_analysis_run, receipt:, **attributes) ]
  end

  def open_progress(receipt)
    trigger = find("##{receipt.dom_target_id} .receipt-processing-trigger")
    panel_id = trigger["aria-controls"]
    trigger.click unless trigger["aria-expanded"] == "true"
    expect(page).to have_css("##{panel_id}.is-open")
    panel_id
  end

  def progress_snapshot(panel_id)
    page.evaluate_script(<<~JAVASCRIPT, panel_id)
      (() => {
        const panel = document.getElementById(arguments[0])
        return Array.from(panel.querySelectorAll('.receipt-processing-step')).map((step) => {
          const classes = Array.from(step.classList)
          return {
            node: classes.find((name) => /^receipt-processing-step-(done|active|pending)$/.test(name)) || null,
            interval: classes.find((name) => /^receipt-processing-interval-(completed|active|pending)$/.test(name)) || null,
            ariaCurrent: step.getAttribute('aria-current')
          }
        })
      })()
    JAVASCRIPT
  end

  def progress_style_snapshot(panel_id)
    page.evaluate_script(<<~JAVASCRIPT, panel_id)
      (() => {
        const panel = document.getElementById(arguments[0])
        const completed = panel.querySelector('.receipt-processing-interval-completed')
        const active = panel.querySelector('.receipt-processing-interval-active')
        const pending = panel.querySelector('.receipt-processing-interval-pending')
        const activeNode = panel.querySelector('.receipt-processing-step-active .receipt-processing-step-dot')
        const completedNode = panel.querySelector('.receipt-processing-step-done .receipt-processing-step-dot')
        const panelRect = panel.getBoundingClientRect()
        const activeBase = window.getComputedStyle(active, '::after')
        const activeGlint = window.getComputedStyle(active, '::before')
        const activeNodeStyle = window.getComputedStyle(activeNode)

        return {
          completedBase: completed ? window.getComputedStyle(completed, '::after').backgroundColor : null,
          activeBase: activeBase.backgroundColor,
          pendingBase: pending ? window.getComputedStyle(pending, '::after').backgroundColor : null,
          activeAnimation: activeGlint.animationName,
          activeAnimationDuration: activeGlint.animationDuration,
          activeGlintImage: activeGlint.backgroundImage,
          activeGlintWidth: activeGlint.width,
          activeGlintHeight: activeGlint.height,
          activeNodeBackground: activeNodeStyle.backgroundColor,
          activeNodeRing: activeNodeStyle.boxShadow,
          completedNodeBackground: completedNode ? window.getComputedStyle(completedNode).backgroundColor : null,
          nodeAnimation: activeNodeStyle.animationName,
          panelWithinViewport: panelRect.left >= 0 && panelRect.right <= window.innerWidth
        }
      })()
    JAVASCRIPT
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

  it "390pxで各phaseを区別し、Turbo更新・theme・reduced motion・縦配置を維持する" do
    user = create_system_test_user(theme_preference: "light")
    fixtures = %i[processing queued ocr organizing ai finalize].to_h do |phase|
      [ phase, create_processing_fixture(user:, phase:) ]
    end
    terminal_receipts = {
      completed: create(:receipt, :completed, user:, store_name: "進捗完了"),
      review_needed: create(:receipt, :review_needed, user:, store_name: "進捗要確認"),
      failed: create(:receipt, :failed, user:, store_name: "進捗失敗")
    }
    expected = {
      processing: [
        { "node" => "receipt-processing-step-active", "interval" => "receipt-processing-interval-active", "ariaCurrent" => "step" },
        { "node" => "receipt-processing-step-pending", "interval" => "receipt-processing-interval-pending", "ariaCurrent" => nil },
        { "node" => "receipt-processing-step-pending", "interval" => "receipt-processing-interval-pending", "ariaCurrent" => nil },
        { "node" => "receipt-processing-step-pending", "interval" => nil, "ariaCurrent" => nil }
      ],
      queued: nil,
      ocr: [
        { "node" => "receipt-processing-step-done", "interval" => "receipt-processing-interval-completed", "ariaCurrent" => nil },
        { "node" => "receipt-processing-step-active", "interval" => "receipt-processing-interval-active", "ariaCurrent" => "step" },
        { "node" => "receipt-processing-step-pending", "interval" => "receipt-processing-interval-pending", "ariaCurrent" => nil },
        { "node" => "receipt-processing-step-pending", "interval" => nil, "ariaCurrent" => nil }
      ],
      organizing: nil,
      ai: [
        { "node" => "receipt-processing-step-done", "interval" => "receipt-processing-interval-completed", "ariaCurrent" => nil },
        { "node" => "receipt-processing-step-done", "interval" => "receipt-processing-interval-completed", "ariaCurrent" => nil },
        { "node" => "receipt-processing-step-active", "interval" => "receipt-processing-interval-active", "ariaCurrent" => "step" },
        { "node" => "receipt-processing-step-pending", "interval" => nil, "ariaCurrent" => nil }
      ],
      finalize: [
        { "node" => "receipt-processing-step-done", "interval" => "receipt-processing-interval-completed", "ariaCurrent" => nil },
        { "node" => "receipt-processing-step-done", "interval" => "receipt-processing-interval-completed", "ariaCurrent" => nil },
        { "node" => "receipt-processing-step-done", "interval" => "receipt-processing-interval-completed", "ariaCurrent" => nil },
        { "node" => "receipt-processing-step-active", "interval" => nil, "ariaCurrent" => "step" }
      ]
    }
    expected[:queued] = expected.fetch(:processing)
    expected[:organizing] = expected.fetch(:ocr)

    sign_in_through_browser(user)
    wait_for_stimulus_controller("receipt-processing-sync")

    aggregate_failures do
      expect(page.evaluate_script("window.innerWidth")).to eq(390)
      expect(page).to have_css("html[data-theme='light']")
      fixtures.each do |phase, (receipt, _run)|
        expect(progress_snapshot(open_progress(receipt))).to eq(expected.fetch(phase))
      end
      terminal_receipts.each_value do |receipt|
        expect(page).to have_no_css("##{receipt.dom_target_id} .receipt-processing-trigger")
      end
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    end

    ocr_receipt, ocr_run = fixtures.fetch(:ocr)
    ocr_panel_id = open_progress(ocr_receipt)
    light_styles = progress_style_snapshot(ocr_panel_id)
    aggregate_failures do
      expect(light_styles.fetch("activeBase")).to eq(light_styles.fetch("pendingBase"))
      expect(light_styles.fetch("completedBase")).not_to eq(light_styles.fetch("pendingBase"))
      expect(light_styles.fetch("activeAnimation")).to eq("receipt-processing-interval-flow")
      expect(light_styles.fetch("activeAnimationDuration")).to eq("1.8s")
      expect(light_styles.fetch("activeGlintImage")).to include("linear-gradient")
      expect(light_styles.fetch("activeNodeBackground")).not_to eq(light_styles.fetch("completedNodeBackground"))
      expect(light_styles.fetch("activeNodeRing")).not_to eq("none")
      expect(light_styles.fetch("nodeAnimation")).to eq("receipt-processing-step-pulse")
      expect(light_styles.fetch("panelWithinViewport")).to be(true)
    end

    user.update_columns(theme_preference: "dark")
    page.refresh
    expect(page).to have_css("html[data-theme='dark']")
    dark_styles = progress_style_snapshot(open_progress(ocr_receipt))
    aggregate_failures do
      expect(page.evaluate_script("window.innerWidth")).to eq(390)
      expect(dark_styles.fetch("activeBase")).to eq(dark_styles.fetch("pendingBase"))
      expect(dark_styles.fetch("completedBase")).not_to eq(dark_styles.fetch("pendingBase"))
      expect(dark_styles.fetch("activeAnimation")).to eq("receipt-processing-interval-flow")
      expect(dark_styles.fetch("activeNodeBackground")).not_to eq(dark_styles.fetch("completedNodeBackground"))
      expect(dark_styles.fetch("activeNodeRing")).not_to eq("none")
      expect(dark_styles.fetch("panelWithinViewport")).to be(true)
    end

    page.driver.browser.execute_cdp(
      "Emulation.setEmulatedMedia",
      features: [ { name: "prefers-reduced-motion", value: "reduce" } ]
    )
    reduced_styles = progress_style_snapshot(open_progress(ocr_receipt))
    aggregate_failures do
      expect(page.evaluate_script("window.matchMedia('(prefers-reduced-motion: reduce)').matches")).to be(true)
      expect(reduced_styles.fetch("activeAnimation")).to eq("none")
      expect(reduced_styles.fetch("nodeAnimation")).to eq("none")
      expect(reduced_styles.fetch("activeNodeRing")).not_to eq("none")
    end
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])

    changed_at = [ Time.current, ocr_run.updated_at, ocr_receipt.updated_at ].max + 2.seconds
    ocr_run.update_columns(
      stage: "ai",
      ocr_finished_at: changed_at,
      ai_started_at: changed_at,
      updated_at: changed_at
    )
    force_processing_card_sync
    expect(page).to have_css("##{ocr_receipt.dom_target_id}[data-receipt-card-phase='ai']")
    expect(page).to have_css("##{ocr_panel_id}.is-open")
    aggregate_failures do
      expect(progress_snapshot(ocr_panel_id)).to eq(expected.fetch(:ai))
      expect(progress_style_snapshot(ocr_panel_id).fetch("activeAnimation")).to eq("receipt-processing-interval-flow")
    end

    regressed_at = changed_at - 1.second
    ocr_run.update_columns(
      stage: "ocr",
      ocr_finished_at: nil,
      ai_started_at: nil,
      updated_at: regressed_at
    )
    force_processing_card_sync
    aggregate_failures do
      expect(page).to have_css("##{ocr_receipt.dom_target_id}[data-receipt-card-phase='ai']")
      expect(progress_snapshot(ocr_panel_id)).to eq(expected.fetch(:ai))
    end

    set_viewport(width: 375, height: 812)
    page.refresh
    expect(page.evaluate_script("window.innerWidth")).to eq(375)
    vertical_styles = progress_style_snapshot(open_progress(fixtures.fetch(:organizing).first))
    aggregate_failures do
      expect(vertical_styles.fetch("activeAnimation")).to eq("receipt-processing-interval-flow-vertical")
      expect(vertical_styles.fetch("activeGlintWidth")).to eq("2px")
      expect(vertical_styles.fetch("activeGlintHeight")).not_to eq("2px")
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    end

    expect_browser_console_clean
  end
end
