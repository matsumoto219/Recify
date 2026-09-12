require "rails_helper"
require_relative "../support/system_test_helpers"
require_relative "../support/current_amount_inspector_helpers"

RSpec.describe "管理者の現在の計算表示", type: :system do
  include CurrentAmountInspectorHelpers

  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  it "詳細をmouseとkeyboardで開閉し、reloadと履歴移動でも現在値を表示する" do
    admin = create_system_test_user(admin: true)
    receipt = create(:receipt, amount_calculation_profile: current_amount_profile)
    run = create(:receipt_analysis_run, :succeeded, receipt: receipt)
    sign_in_through_browser(admin)
    visit admin_receipt_analysis_run_path(run.run_key)

    inspector = find("[data-current-amount-inspector]")
    expect(inspector).to have_content("現在の計算")
    expect(inspector).to have_content("解析時点の履歴ではありません")
    detail = inspector.find("details", match: :first)
    detail.find("summary").click
    expect(inspector).to have_css("details[open]", count: 1)
    detail.find("summary").send_keys(:enter)
    expect(inspector).to have_no_css("details[open]")
    detail.find("summary").send_keys(:space)
    expect(inspector).to have_css("details[open]", count: 1)
    detail.find("summary").send_keys(:tab)
    expect(page.evaluate_script("document.activeElement.tagName")).to eq("SUMMARY")
    page.driver.browser.action.key_down(:shift).send_keys(:tab).key_up(:shift).perform
    expect(detail.find("summary")).to eq(page.find(":focus"))

    updated = current_amount_profile
    updated["context"] = "edit_save"
    receipt.update!(amount_calculation_profile: updated)
    page.refresh
    expect(find("[data-current-amount-inspector]")).to have_content("編集保存")
    page.execute_script("window.currentAmountInspectorNavigation = true")
    find("a[href='#{admin_receipt_analysis_runs_path}']", match: :first).click
    expect(page).to have_current_path(admin_receipt_analysis_runs_path)
    expect(page.evaluate_script("window.currentAmountInspectorNavigation")).to be(true)
    page.go_back
    expect(find("[data-current-amount-inspector]")).to have_content("現在の計算")
    page.go_forward
    expect(page).to have_current_path(admin_receipt_analysis_runs_path)
    expect_browser_console_clean
  end

  it "390pxのlight/darkで長い候補IDと比較表を横overflowなしに表示する", :mobile do
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: true
    )
    admin = create_system_test_user(admin: true)
    profile = current_amount_profile
    long_rate = "0.#{'3' * 70}"
    profile["amount_engine"]["selected_candidate"]["computed_items"][0]["discount_rate"] = long_rate
    receipt = create(:receipt, amount_calculation_profile: profile)
    run = create(:receipt_analysis_run, :succeeded, receipt: receipt)
    sign_in_through_browser(admin)
    visit admin_receipt_analysis_run_path(run.run_key)

    backgrounds = []
    %w[light dark].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      inspector = find("[data-current-amount-inspector]")
      inspector.all("details:not([open])").each { |detail| detail.find("summary").click }
      backgrounds << page.evaluate_script("getComputedStyle(document.querySelector('[data-current-amount-inspector] .token-bg-card-subtle')).backgroundColor")

      aggregate_failures do
        expect(page).to have_css("html[data-theme='#{theme}']")
        expect(inspector).to have_content("候補の比較")
        expect(inspector).to have_content(long_rate)
        expect(page.evaluate_script("window.innerWidth")).to eq(390)
        expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
      end
    end
    expect(backgrounds.uniq.size).to eq(2)
    expect_browser_console_clean
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
