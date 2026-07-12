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
    expect(page.evaluate_script("window.innerWidth")).to eq(390)
    expect(
      page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
    ).to be(true)
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
end
