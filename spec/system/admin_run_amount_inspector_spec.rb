require "rails_helper"
require_relative "../support/system_test_helpers"
require_relative "../support/run_amount_inspector_helpers"

RSpec.describe "管理者の解析当時の計算表示", type: :system do
  include RunAmountInspectorHelpers

  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  it "現在値の編集後も履歴を保持し、keyboard・reload・Turbo履歴移動に対応する" do
    admin = create_system_test_user(admin: true)
    receipt = create(:receipt, amount_calculation_profile: current_amount_profile)
    snapshot = run_amount_snapshot
    run = create(:receipt_analysis_run, :succeeded, receipt: receipt,
      final_result_summary: { amount_calculation_run_snapshot: snapshot })
    sign_in_through_browser(admin)
    visit admin_receipt_analysis_run_path(run.run_key)

    inspector = find("[data-run-amount-inspector]")
    expect(inspector).to have_content("解析当時の計算")
    expect(inspector).to have_content("一部を省略して保存")
    detail = inspector.find("details", match: :first)
    detail.find("summary").click
    expect(inspector).to have_css("details[open]", count: 1)
    detail.find("summary").send_keys(:enter)
    expect(inspector).to have_no_css("details[open]")
    detail.find("summary").send_keys(:space)
    expect(inspector).to have_css("details[open]", count: 1)
    detail.find("summary").send_keys(:tab)
    page.driver.browser.action.key_down(:shift).send_keys(:tab).key_up(:shift).perform
    expect(detail.find("summary")).to eq(page.find(":focus"))

    receipt.update!(amount_calculation_profile: current_amount_profile.merge(
      "context" => "edit_save", "computed" => { "total_amount" => 2378 }, "resolved" => { "total_amount" => 2378 }
    ).except("amount_engine"))
    page.refresh
    expect(find("[data-current-amount-inspector]")).to have_content("2378")
    expect(find("[data-run-amount-inspector]")).to have_content("1100")
    expect(find("[data-run-amount-inspector]")).not_to have_content("2378")
    expect(run.reload.final_result_summary.fetch("amount_calculation_run_snapshot")).to eq(snapshot)
    page.execute_script("window.runAmountInspectorNavigation = true")
    find("a[href='#{admin_receipt_analysis_runs_path}']", match: :first).click
    expect(page).to have_current_path(admin_receipt_analysis_runs_path)
    expect(page.evaluate_script("window.runAmountInspectorNavigation")).to be(true)
    page.go_back
    expect(page).to have_css("[data-run-amount-inspector]")
    page.go_forward
    expect(page).to have_current_path(admin_receipt_analysis_runs_path)
    expect_browser_console_clean
  end

  it "390pxのlight/darkでexact長値と省略内容を表示し旧runは利用不可にする", :mobile do
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: true
    )
    admin = create_system_test_user(admin: true)
    snapshot = run_amount_snapshot
    exact = "123456789012345.#{'1' * 112}"
    snapshot["engine"]["resolved"]["tax_rate"] = exact
    run = create(:receipt_analysis_run, :succeeded, receipt: create(:receipt, amount_calculation_profile: current_amount_profile),
      final_result_summary: { amount_calculation_run_snapshot: snapshot })
    sign_in_through_browser(admin)
    visit admin_receipt_analysis_run_path(run.run_key)

    backgrounds = []
    %w[light dark].each do |theme|
      page.execute_script("document.documentElement.dataset.theme = arguments[0]", theme)
      inspector = find("[data-run-amount-inspector]")
      inspector.all("details:not([open])").each { |detail| detail.find("summary").click }
      backgrounds << page.evaluate_script("getComputedStyle(document.querySelector('[data-run-amount-inspector] .token-bg-card-subtle')).backgroundColor")
      aggregate_failures do
        expect(inspector).to have_content(exact)
        expect(inspector).to have_content("保存件数と省略内容")
        expect(inspector).to have_content("比較候補の計算明細は保存対象外")
        expect(inspector).not_to have_content(/translation missing/i)
        expect(page.evaluate_script("window.innerWidth")).to eq(390)
        expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
      end
    end
    expect(backgrounds.uniq.size).to eq(2)
    run.update!(final_result_summary: {})
    page.refresh
    expect(find("[data-run-amount-inspector]")).to have_content("利用できません")
    expect(find("[data-run-amount-inspector]")).not_to have_content("1100")
    expect_browser_console_clean
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
