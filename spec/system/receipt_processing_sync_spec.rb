require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "レシート処理カードの実Chrome同期", type: :system do
  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  def processing_card_selector(receipt)
    "##{receipt.dom_target_id}"
  end

  def force_processing_card_sync
    result = page.evaluate_async_script(<<~JAVASCRIPT, Capybara.default_max_wait_time * 1000)
      const timeoutMilliseconds = arguments[0]
      const done = arguments[arguments.length - 1]
      const deadline = window.performance.now() + timeoutMilliseconds

      const waitForIdleController = (resolve, reject) => {
        const controller = window.Stimulus?.controllers?.find((candidate) => {
          return candidate.identifier === 'receipt-processing-sync' &&
            candidate.element.id === 'receipts-results'
        })

        if (controller && !controller.syncInFlight) {
          resolve(controller)
          return
        }
        if (window.performance.now() >= deadline) {
          reject(new Error('receipt-processing-sync controller did not become idle'))
          return
        }

        window.setTimeout(() => waitForIdleController(resolve, reject), 25)
      }

      new Promise(waitForIdleController)
        .then(async (controller) => {
          const completedBefore = controller.completedPollCount
          await controller.syncNow()
          done({
            ok: controller.completedPollCount > completedBefore,
            completedPollCount: controller.completedPollCount
          })
        })
        .catch((error) => done({ ok: false, error: error.message }))
    JAVASCRIPT

    expect(result.fetch("ok")).to be(true), result.inspect
  end

  def clear_scheduled_processing_card_sync
    cleared = page.evaluate_async_script(<<~JAVASCRIPT, Capybara.default_max_wait_time * 1000)
      const timeoutMilliseconds = arguments[0]
      const done = arguments[arguments.length - 1]
      const deadline = window.performance.now() + timeoutMilliseconds

      const clearWhenIdle = () => {
        const controller = window.Stimulus?.controllers?.find((candidate) => {
          return candidate.identifier === 'receipt-processing-sync' &&
            candidate.element.id === 'receipts-results'
        })
        if (controller && !controller.syncInFlight) {
          controller.clearPollTimer()
          done(true)
          return
        }
        if (window.performance.now() >= deadline) {
          done(false)
          return
        }

        window.setTimeout(clearWhenIdle, 25)
      }

      clearWhenIdle()
    JAVASCRIPT

    expect(cleared).to be(true)
  end

  def create_processing_fixture(user)
    receipt = create(:receipt, :processing, :with_image, user:, store_name: "処理同期店")
    run = create(
      :receipt_analysis_run,
      :running,
      receipt:,
      stage: "ocr",
      ocr_started_at: Time.current
    )
    [ receipt, run ]
  end

  it "revision一致時はDOMを保ち、OCRからAIへの更新時だけカードを置換する" do
    user = create_system_test_user
    receipt, run = create_processing_fixture(user)
    card_selector = processing_card_selector(receipt)

    sign_in_through_browser(user)
    wait_for_stimulus_controller("receipt-processing-sync")
    expect(page).to have_css("#{card_selector}[data-receipt-card-phase='ocr']")

    initial_revision = find(card_selector)["data-receipt-card-state-revision"]
    page.execute_script("document.querySelector(arguments[0]).dataset.syncSentinel = 'unchanged'", card_selector)
    force_processing_card_sync

    unchanged_card = find(card_selector)
    aggregate_failures do
      expect(unchanged_card["data-sync-sentinel"]).to eq("unchanged")
      expect(unchanged_card["data-receipt-card-state-revision"]).to eq(initial_revision)
    end

    clear_scheduled_processing_card_sync
    changed_at = [ Time.current, run.updated_at, receipt.updated_at ].max + 2.seconds
    run.update_columns(
      stage: "ai",
      ocr_finished_at: changed_at,
      ai_started_at: changed_at,
      updated_at: changed_at
    )
    force_processing_card_sync

    expect(page).to have_css("#{card_selector}[data-receipt-card-phase='ai']")
    updated_card = find(card_selector)
    aggregate_failures do
      expect(updated_card["data-sync-sentinel"]).to be_nil
      expect(updated_card["data-receipt-card-state-revision"]).not_to eq(initial_revision)
      expect(updated_card["data-receipt-card-terminal"]).to eq("false")
      expect(updated_card["data-receipt-processing-sync-target"]).to eq("card")
    end
    expect_browser_console_clean
  end

  it "processingからcompletedへの更新を反映してpolling対象から外す" do
    user = create_system_test_user
    receipt, run = create_processing_fixture(user)
    card_selector = processing_card_selector(receipt)

    sign_in_through_browser(user)
    wait_for_stimulus_controller("receipt-processing-sync")
    expect(page).to have_css("#{card_selector}[data-receipt-card-phase='ocr']")

    clear_scheduled_processing_card_sync
    terminal_at = [ Time.current, run.updated_at, receipt.updated_at ].max + 2.seconds
    run.update_columns(
      status: "succeeded",
      stage: "completed",
      finalized_at: terminal_at,
      updated_at: terminal_at
    )
    receipt.update_columns(status: "completed", updated_at: terminal_at)
    force_processing_card_sync

    expect(page).to have_css("#{card_selector}[data-receipt-card-phase='completed']")
    terminal_card = find(card_selector)
    aggregate_failures do
      expect(terminal_card["data-receipt-card-terminal"]).to eq("true")
      expect(terminal_card["data-receipt-processing-sync-target"]).to be_nil
      expect(terminal_card).to have_link(I18n.t("receipt_cards.actions.show"))
      expect(terminal_card).to have_link(I18n.t("receipt_cards.actions.edit"))
    end

    polling_state = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const controller = window.Stimulus.controllers.find((candidate) => {
          return candidate.identifier === 'receipt-processing-sync' &&
            candidate.element.id === 'receipts-results'
        })
        return { hasCardTarget: controller.hasCardTarget, pollTimer: controller.pollTimer }
      })()
    JAVASCRIPT
    aggregate_failures do
      expect(polling_state.fetch("hasCardTarget")).to be(false)
      expect(polling_state.fetch("pollTimer")).to be_nil
    end
    expect_browser_console_clean
  end
end
