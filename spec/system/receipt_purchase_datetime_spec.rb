require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "解析した購入日時の表示と編集", type: :system do
  def finalize_receipt(user, settlement_times: [ "07:36" ])
    receipt = create(:receipt, :processing, :with_image, user: user)
    sources = [ { role: "service_start", time: "06:08" } ] +
      settlement_times.map { |time| { role: "settlement", time: time } }
    sources = sources.each_with_index.map do |source, index|
      {
        candidate_id: "datetime_line_#{index}", source_path: "lines[#{index}]", line_index: index,
        date: "2026-09-01", precision: "datetime", association: "exact"
      }.merge(source)
    end
    ocr_result = {
      success: true,
      lines: [ "サンプル売店", "精算 2026-09-01 07:36", "検証品 100", "合計 100", "現金 100" ],
      candidates: {
        store_name: "サンプル売店", purchased_at_text: "2026-09-01 06:08", country_region: "JPN",
        total_amount: 100, payment_method_text: "現金",
        items: [ { raw_text: "検証品", price: 100, quantity: 1, line_total: 100, tax_rate: 0, confidence: 0.99 } ],
        payments: [ { method: "Cash", amount: 100 } ], tax_details: [],
        purchased_at_evidence: {
          schema_version: "purchased_at_evidence_v1", candidates: sources,
          complete: true, truncated: false, omitted_count: 0, invalid: false
        }
      }
    }
    ai_result = {
      success: true, needs_review: true,
      review_reasons: %w[purchased_at_missing purchased_at_uncertain purchased_at_conflicted],
      receipt_attributes: { purchased_at_text: "2026-09-01 06:08" },
      receipt_items_attributes: [ { index: 0, category: "daily_goods", needs_review: false } ]
    }
    run = create(:receipt_analysis_run, receipt: receipt)
    Receipts::Processing.record_ocr_snapshot(run, ocr_result)
    Receipts::Processing.record_ai_normalized_result(run, ai_result)
    decision = Receipts::Processing.finalize_decision_from_snapshot(
      schema_version: "receipt_analysis_run_finalize_decision_v1", strategy: "ai_success"
    )
    Receipts::Processing.record_finalize_decision(run, decision)
    Receipts::Processing.run_finalize(run)
    expect(run.reload.status).to eq("succeeded")
    [ receipt.reload, run ]
  end

  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  it "精算日時をdesktopと390pxの明暗テーマで表示しreload後も維持する" do
    user = create_system_test_user(password: "password")
    receipt, = finalize_receipt(user)
    expect(receipt.purchased_at).to eq(Time.zone.parse("2026-09-01 07:36"))
    expect(receipt.review_reasons).to be_empty
    sign_in_through_browser(user)
    visit receipt_path(receipt)

    [ 1440, 390 ].each do |width|
      page.driver.browser.execute_cdp(
        "Emulation.setDeviceMetricsOverride",
        width: width,
        height: 1000,
        deviceScaleFactor: 1,
        mobile: false
      )
      expect(page).to have_text("07:36")
      click_link I18n.t("common.edit"), match: :first
      expect(page).to have_current_path(edit_receipt_path(receipt), ignore_query: true)
      wait_for_stimulus_controller("receipt-form")

      %w[light dark].each do |theme|
        page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
        expect(find("#receipt_purchased_on").value).to eq("2026-09-01")
        time_input = find("#receipt_purchased_time")
        expect(time_input.value).to eq("07:36")
        expect(time_input[:class].split).not_to include("input-field-error")
        time_input.click
        time_input.send_keys(:tab)
        expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
        page.save_screenshot(Rails.root.join("tmp/screenshots/purchase-datetime-#{width}-#{theme}.png"))
      end

      page.refresh
      expect(find("#receipt_purchased_time").value).to eq("07:36")
      click_link I18n.t("receipts.form.breadcrumbs.show"), match: :first
      expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
      page.go_back
      expect(page).to have_current_path(edit_receipt_path(receipt), ignore_query: true)
      expect(find("#receipt_purchased_time").value).to eq("07:36")
      page.go_forward
      expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
      expect(page).to have_text("07:36")
    end
    expect_browser_console_clean
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  it "競合した時刻の確認枠を表示し利用者の日時修正を保存後の重複Finalizeで上書きしない", mobile: true do
    user = create_system_test_user(password: "password")
    receipt, run = finalize_receipt(user, settlement_times: [ "07:36", "08:00" ])
    expect(receipt.purchased_at).to eq(Time.zone.parse("2026-09-01"))
    expect(receipt.review_reasons).to eq([ "purchased_at_conflicted" ])
    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    expect(find("#receipt_purchased_on").value).to eq("2026-09-01")
    expect(find("#receipt_purchased_time")[:class].split).to include("input-field-error")
    fill_in "receipt_purchased_time", with: "08:10"
    click_button I18n.t("receipts.form.buttons.save"), match: :first
    expect(page).to have_current_path(receipt_path(receipt))
    expect(page).to have_text("08:10")
    expect(receipt.reload.review_reasons).not_to include("purchased_at_conflicted")

    Receipts::Processing.run_finalize(run)
    page.refresh
    expect(receipt.reload.purchased_at).to eq(Time.zone.parse("2026-09-01 08:10"))
    expect(page).to have_text("08:10")
    expect_browser_console_clean
  end
end
