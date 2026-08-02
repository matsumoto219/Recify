require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "レシート編集の実Chrome入力回帰", type: :system, mobile: true do
  before do
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: true
    )
  end

  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  def receipt_item_row
    find("[data-receipt-form-target='itemRow']", match: :first)
  end

  def expanded_receipt_item_row
    item_row = receipt_item_row
    toggle = item_row.find("[data-receipt-form-target='itemDetailsToggle']", match: :first)
    toggle.click unless toggle["aria-expanded"] == "true"
    expect(item_row).to have_css("input[name$='[price]']")
    item_row
  end

  def expect_mobile_viewport_without_horizontal_overflow
    expect_viewport_without_horizontal_overflow(390)
  end

  def expect_viewport_without_horizontal_overflow(width)
    expect(page.evaluate_script("window.innerWidth")).to eq(width)
    expect(
      page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
    ).to be(true)
  end

  def set_viewport(width:, height:, mobile:)
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: width,
      height: height,
      deviceScaleFactor: 1,
      mobile: mobile
    )
  end

  def receipt_adjustment_target_id(adjustment)
    "receipt-adjustment-#{adjustment.id}"
  end

  def receipt_adjustment_row(adjustment)
    find("##{receipt_adjustment_target_id(adjustment)}")
  end

  def expect_adjustment_row_expanded(row, target_id)
    panel_id = "#{target_id}-details"

    aggregate_failures do
      expect(row).to have_css(
        "[data-receipt-form-target='adjustmentDetailsPanel']##{panel_id}.is-open[aria-hidden='false']:not([inert])",
        visible: :all
      )
      expect(row).to have_css(
        "[data-receipt-form-target='adjustmentDetailsToggle'][aria-controls='#{panel_id}'][aria-expanded='true']",
        count: 2,
        visible: :all
      )
    end
  end

  def expect_adjustment_row_collapsed(row, target_id)
    panel_id = "#{target_id}-details"

    aggregate_failures do
      expect(row).to have_css(
        "[data-receipt-form-target='adjustmentDetailsPanel']##{panel_id}[aria-hidden='true'][inert]:not(.is-open)",
        visible: :all
      )
      expect(row).to have_css(
        "[data-receipt-form-target='adjustmentDetailsToggle'][aria-controls='#{panel_id}'][aria-expanded='false']",
        count: 2,
        visible: :all
      )
    end
  end

  def visible_adjustment_toggle(row)
    row.find("[data-receipt-form-target='adjustmentDetailsToggle']", visible: true)
  end

  def element_has_focus?(element)
    page.evaluate_script("document.activeElement === arguments[0]", element)
  end

  def expect_visible_adjustment_toggle_focused(row)
    expect(row).to have_css(
      "[data-receipt-form-target='adjustmentDetailsToggle']:focus",
      visible: true
    )
  end

  def wait_for_visual_motion_to_finish(element)
    settled = page.evaluate_async_script(<<~JAVASCRIPT, element, Capybara.default_max_wait_time * 1000)
      const target = arguments[0]
      const timeoutMilliseconds = arguments[1]
      const done = arguments[arguments.length - 1]
      let completed = false

      const finish = (result) => {
        if (completed) return

        completed = true
        done(result)
      }

      window.setTimeout(() => finish(false), timeoutMilliseconds)
      window.requestAnimationFrame(() => {
        window.requestAnimationFrame(() => {
          const animations = target.getAnimations({ subtree: true })
          Promise.all(animations.map((animation) => animation.finished.catch(() => undefined)))
            .then(() => finish(true))
        })
      })
    JAVASCRIPT

    expect(settled).to be(true), "CSS motion did not finish"
  end

  def click_mobile_save_button
    actions_ready = page.evaluate_async_script(<<~JAVASCRIPT)
      const done = arguments[arguments.length - 1]
      document.activeElement?.blur()

      window.setTimeout(() => {
        window.scrollBy(0, 80)
        window.setTimeout(() => done(true), 350)
      }, 200)
    JAVASCRIPT
    expect(actions_ready).to be(true)
    expect(page).to have_css(
      "[data-mobile-ui-target='actions']:not(.pointer-events-none):not(.translate-y-full)"
    )

    within("[data-mobile-ui-target='actions']") do
      click_button I18n.t("receipts.form.buttons.save")
    end
  end

  def expect_only_validation_failure_in_browser_console(receipt)
    severe_entries = page.driver.browser.logs.get(:browser).select do |entry|
      entry.level == "SEVERE" && !blocked_external_font_entry?(entry)
    end
    validation_entries, unexpected_entries = severe_entries.partition do |entry|
      entry.message.include?(receipt_path(receipt)) &&
        entry.message.include?("422 (Unprocessable Content)")
    end

    expect(validation_entries.size).to eq(1)
    expect(unexpected_entries).to be_empty
  end

  it "不正な単価を保持し、修正後に明細を保存できる" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "モバイル編集店",
      purchased_at: Time.zone.local(2026, 7, 12, 12, 0, 0),
      payment_method: "cash",
      subtotal_amount: 91,
      tax_amount: 9,
      total_amount: 100
    )
    item = receipt.receipt_items.create!(
      raw_text: "OCR元商品名",
      confirmed_name: "編集前商品",
      price: 100,
      quantity: 1,
      quantity_unit_code: "each",
      tax_rate: BigDecimal("0.1"),
      line_total: 100,
      needs_review: false,
      review_reasons: []
    )
    queue_adapter = ActiveJob::Base.queue_adapter
    expect(queue_adapter).to respond_to(:enqueued_jobs)
    queued_job_count = queue_adapter.enqueued_jobs.size

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    expect_mobile_viewport_without_horizontal_overflow

    item_row = expanded_receipt_item_row
    item_row.find("input[name$='[confirmed_name]']").set("入力保持商品")
    item_row.find("input[name$='[price]']").set("1e2")
    click_mobile_save_button

    expect(page).to have_content(I18n.t("receipts.form.errors.invalid_numeric_input"))
    expect_only_validation_failure_in_browser_console(receipt)
    item_row = expanded_receipt_item_row
    expect(item_row.find("input[name$='[confirmed_name]']").value).to eq("入力保持商品")
    expect(item_row.find("input[name$='[price]']").value).to eq("1e2")
    expect(item.reload).to have_attributes(
      confirmed_name: "編集前商品",
      raw_text: "OCR元商品名",
      price: 100,
      line_total: 100
    )
    expect(receipt.reload.total_amount).to eq(100)
    expect(queue_adapter.enqueued_jobs.size).to eq(queued_job_count)
    expect_mobile_viewport_without_horizontal_overflow

    item_row.find("input[name$='[confirmed_name]']").set("保存後商品")
    item_row.find("input[name$='[price]']").set("200")
    click_mobile_save_button

    expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
    expect(page).to have_content("保存後商品")
    expect(item.reload).to have_attributes(
      confirmed_name: "保存後商品",
      raw_text: "OCR元商品名",
      price: 200,
      line_total: 200
    )
    expect(receipt.reload).to have_attributes(
      subtotal_amount: 182,
      tax_amount: 18,
      total_amount: 200,
      status: "completed"
    )
    expect_mobile_viewport_without_horizontal_overflow
    new_jobs = queue_adapter.enqueued_jobs.drop(queued_job_count)
    expect(new_jobs.map { |job| job[:job] }).to eq([ Turbo::Streams::ActionBroadcastJob ])
    expect_browser_console_clean
  end

  it "review reasonリンクから該当明細を展開して入力できる" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "レビュー対象店",
      purchased_at: Time.zone.local(2026, 7, 12, 12, 0, 0),
      payment_method: "cash",
      subtotal_amount: 91,
      tax_amount: 9,
      total_amount: 100
    )
    review_item = receipt.receipt_items.create!(
      raw_text: "OCR要確認商品",
      confirmed_name: "要確認商品",
      price: 100,
      quantity: 1,
      quantity_unit_code: "each",
      tax_rate: BigDecimal("0.1"),
      line_total: 100,
      needs_review: true,
      review_reasons: [ "item_tax_rate_uncertain" ]
    )
    receipt.update!(status: "review_needed", review_reasons: [])

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")

    target_id = "#{ReceiptsHelper::RECEIPT_REVIEW_TARGET_ITEM_ID_PREFIX}#{review_item.id}"
    item_row = find("##{target_id}")
    panel_selector = "[data-receipt-form-target='itemDetailsPanel']"
    toggle_selector = "[data-receipt-form-target='itemDetailsToggle']"

    aggregate_failures do
      expect(page.evaluate_script("window.location.hash")).to eq("")
      expect(item_row.find(panel_selector, visible: :all)["aria-hidden"]).to eq("true")
      expect(item_row).to have_css(
        "#{toggle_selector}[aria-expanded='false']",
        count: 2,
        visible: :all
      )
    end

    expect(page).to have_css("[data-receipt-review-notes-card][data-collapsible-enhanced='true']")
    review_card = find("[data-receipt-review-notes-card]")
    review_card.find("[data-receipt-notes-summary]").click

    target_link_selector = "a[data-review-reason-target-item='#{target_id}']"
    expect(review_card).to have_css(target_link_selector)
    review_card.find(target_link_selector).click

    expect(item_row).to have_css(
      "#{panel_selector}.is-open[aria-hidden='false']:not([inert])",
      visible: :all
    )
    expect(item_row).to have_css(
      "#{toggle_selector}[aria-expanded='true']",
      count: 2,
      visible: :all
    )
    expect(page.evaluate_script("window.location.hash")).to eq("##{target_id}")
    expect(element_has_focus?(item_row.find(toggle_selector, visible: true))).to be(false)

    tax_rate_input = item_row.find("[data-receipt-form-target='taxRateInput']")
    tax_rate_input.set("8")
    expect(tax_rate_input.value).to eq("8")

    expect_mobile_viewport_without_horizontal_overflow
    expect_browser_console_clean
  end

  it "review reasonリンクから対象調整行だけを展開し、既存の展開状態とARIAを維持する" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "調整レビュー対象店",
      purchased_at: Time.zone.local(2026, 7, 12, 12, 0, 0),
      payment_method: "cash",
      subtotal_amount: 100,
      tax_amount: 10,
      total_amount: 110
    )
    receipt.receipt_items.create!(
      raw_text: "展開維持商品",
      confirmed_name: "展開維持商品",
      price: 110,
      quantity: 1,
      quantity_unit_code: "each",
      tax_rate: BigDecimal("0.1"),
      line_total: 110,
      needs_review: false,
      review_reasons: []
    )
    first_review_adjustment = create(
      :receipt_adjustment,
      receipt: receipt,
      label: "要確認調整A",
      needs_review: true,
      review_reasons: [ "adjustment_uncertain" ],
      position_index: 1
    )
    second_review_adjustment = create(
      :receipt_adjustment,
      receipt: receipt,
      label: "要確認調整B",
      needs_review: true,
      review_reasons: [ "adjustment_uncertain" ],
      position_index: 2
    )
    already_open_adjustment = create(
      :receipt_adjustment,
      receipt: receipt,
      label: "手動展開済み調整",
      position_index: 3
    )
    untouched_adjustment = create(
      :receipt_adjustment,
      receipt: receipt,
      label: "未展開調整",
      position_index: 4
    )
    receipt.update!(status: "review_needed", review_reasons: [])

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")

    expanded_item_row = expanded_receipt_item_row
    already_open_row = receipt_adjustment_row(already_open_adjustment)
    visible_adjustment_toggle(already_open_row).click
    already_open_target_id = receipt_adjustment_target_id(already_open_adjustment)
    expect_adjustment_row_expanded(already_open_row, already_open_target_id)

    review_card = find("[data-receipt-review-notes-card]")
    review_card.find("[data-receipt-notes-summary]").click

    first_target_id = receipt_adjustment_target_id(first_review_adjustment)
    first_target_link = review_card.find(
      "a[data-review-reason-target-adjustment='#{first_target_id}']"
    )
    first_target_link.click

    first_row = receipt_adjustment_row(first_review_adjustment)
    second_row = receipt_adjustment_row(second_review_adjustment)
    untouched_row = receipt_adjustment_row(untouched_adjustment)
    expect_adjustment_row_expanded(first_row, first_target_id)
    expect_adjustment_row_expanded(already_open_row, already_open_target_id)
    expect(expanded_item_row).to have_css(
      "[data-receipt-form-target='itemDetailsPanel'].is-open[aria-hidden='false']:not([inert])",
      visible: :all
    )
    expect_adjustment_row_collapsed(
      second_row,
      receipt_adjustment_target_id(second_review_adjustment)
    )
    expect_adjustment_row_collapsed(
      untouched_row,
      receipt_adjustment_target_id(untouched_adjustment)
    )
    expect(page.evaluate_script("window.location.hash")).to eq("##{first_target_id}")
    expect_visible_adjustment_toggle_focused(first_row)

    second_target_id = receipt_adjustment_target_id(second_review_adjustment)
    review_card.find(
      "a[data-review-reason-target-adjustment='#{second_target_id}']"
    ).send_keys(:enter)

    expect_adjustment_row_expanded(second_row, second_target_id)
    expect_adjustment_row_expanded(first_row, first_target_id)
    expect_adjustment_row_expanded(already_open_row, already_open_target_id)
    expect_adjustment_row_collapsed(
      untouched_row,
      receipt_adjustment_target_id(untouched_adjustment)
    )
    expect(page.evaluate_script("window.location.hash")).to eq("##{second_target_id}")
    expect_visible_adjustment_toggle_focused(second_row)

    page.execute_script("document.activeElement?.blur()")
    page.go_back
    expect(page.evaluate_script("window.location.hash")).to eq("##{first_target_id}")
    expect_adjustment_row_expanded(first_row, first_target_id)
    expect_adjustment_row_expanded(second_row, second_target_id)
    expect(element_has_focus?(visible_adjustment_toggle(first_row))).to be(false)

    page.go_forward
    expect(page.evaluate_script("window.location.hash")).to eq("##{second_target_id}")
    expect_adjustment_row_expanded(first_row, first_target_id)
    expect_adjustment_row_expanded(second_row, second_target_id)
    expect(element_has_focus?(visible_adjustment_toggle(second_row))).to be(false)
    expect_mobile_viewport_without_horizontal_overflow
    expect_browser_console_clean
  end

  it "direct hashでは調整行を展開してもfocusを移動しない" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "直接リンク確認店",
      purchased_at: Time.zone.local(2026, 7, 12, 12, 0, 0),
      payment_method: "cash",
      subtotal_amount: 100,
      tax_amount: 10,
      total_amount: 110
    )
    adjustment = create(
      :receipt_adjustment,
      receipt: receipt,
      label: "直接リンク対象調整",
      needs_review: true,
      review_reasons: [ "adjustment_uncertain" ]
    )
    receipt.update!(status: "review_needed", review_reasons: [])

    sign_in_through_browser(user)
    set_viewport(width: 1440, height: 1000, mobile: false)
    target_id = receipt_adjustment_target_id(adjustment)
    visit "#{edit_receipt_path(receipt)}##{target_id}"
    wait_for_stimulus_controller("receipt-form")

    row = receipt_adjustment_row(adjustment)
    toggle = visible_adjustment_toggle(row)
    expect_adjustment_row_expanded(row, target_id)
    expect(page.evaluate_script("window.location.hash")).to eq("##{target_id}")
    expect(element_has_focus?(toggle)).to be(false)
    expect_viewport_without_horizontal_overflow(1440)

    review_card = find("[data-receipt-review-notes-card]")
    review_card.find("[data-receipt-notes-summary]").click
    review_card.find("a[data-review-reason-target-adjustment='#{target_id}']").click

    expect_adjustment_row_expanded(row, target_id)
    expect_visible_adjustment_toggle_focused(row)
    expect_viewport_without_horizontal_overflow(1440)
    expect_browser_console_clean
  end

  it "調整行のreview reasonリンクをダブルクリックしてもフォームを送信しない" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "ダブルクリック確認店",
      purchased_at: Time.zone.local(2026, 7, 12, 12, 0, 0),
      payment_method: "cash",
      subtotal_amount: 100,
      tax_amount: 10,
      total_amount: 110
    )
    adjustment = create(
      :receipt_adjustment,
      receipt: receipt,
      label: "ダブルクリック対象調整",
      needs_review: true,
      review_reasons: [ "adjustment_uncertain" ]
    )
    receipt.update!(status: "review_needed", review_reasons: [])
    lock_version = receipt.lock_version

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")

    target_id = receipt_adjustment_target_id(adjustment)
    review_card = find("[data-receipt-review-notes-card]")
    review_card.find("[data-receipt-notes-summary]").click
    wait_for_visual_motion_to_finish(review_card)
    target_link = review_card.find("a[data-review-reason-target-adjustment='#{target_id}']")
    page.driver.browser.action.move_to(target_link.native).click.pause(duration: 0.2).click.perform

    expect(page).to have_current_path(edit_receipt_path(receipt), ignore_query: true)
    expect(page.evaluate_script("window.location.hash")).to eq("##{target_id}")
    expect(receipt.reload.lock_version).to eq(lock_version)
    expect_adjustment_row_expanded(receipt_adjustment_row(adjustment), target_id)
    expect_mobile_viewport_without_horizontal_overflow
    expect_browser_console_clean
  end

  it "調整行のhashから別画面へ移動して戻っても編集画面を復元する" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "履歴復元確認店",
      purchased_at: Time.zone.local(2026, 7, 13, 12, 0, 0),
      payment_method: "cash",
      subtotal_amount: 100,
      tax_amount: 10,
      total_amount: 110
    )
    adjustment = create(
      :receipt_adjustment,
      receipt: receipt,
      label: "履歴復元対象調整",
      needs_review: true,
      review_reasons: [ "adjustment_uncertain" ]
    )
    second_adjustment = create(
      :receipt_adjustment,
      receipt: receipt,
      label: "履歴復元対象調整2",
      needs_review: true,
      review_reasons: [ "adjustment_uncertain" ]
    )
    receipt.update!(status: "review_needed", review_reasons: [])

    sign_in_through_browser(user)
    target_id = receipt_adjustment_target_id(adjustment)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")

    review_card = find("[data-receipt-review-notes-card]")
    review_card.find("[data-receipt-notes-summary]").click
    review_card.find("a[data-review-reason-target-adjustment='#{target_id}']").click
    second_target_id = receipt_adjustment_target_id(second_adjustment)
    review_card.find("a[data-review-reason-target-adjustment='#{second_target_id}']").click
    review_card.find("a[data-review-reason-target-adjustment='#{target_id}']").click
    expect(page.evaluate_script("window.location.hash")).to eq("##{target_id}")
    expect(page.evaluate_script("Boolean(window.history.state?.turbo)")).to be(true)

    find("a[href='#{settings_path}']", visible: true).click
    expect(page).to have_current_path(settings_path)

    page.go_back
    expect(page).to have_current_path(edit_receipt_path(receipt), ignore_query: true)
    wait_for_stimulus_controller("receipt-form")

    row = receipt_adjustment_row(adjustment)
    expect_adjustment_row_expanded(row, target_id)
    expect(element_has_focus?(visible_adjustment_toggle(row))).to be(false)
    expect_mobile_viewport_without_horizontal_overflow
    expect_browser_console_clean
  end
end
