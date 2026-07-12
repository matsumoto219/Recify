require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "管理dashboardの実Chrome表示", type: :system do
  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  it "外部サービスstatus cardをprovider APIなしで再取得する" do
    admin = create_system_test_user(admin: true)
    sign_in_through_browser(admin)
    visit admin_root_path

    expect(page).to have_content(I18n.t("admin.dashboard.title"))
    wait_for_stimulus_controller("service-status-polling")
    polling_root = find("[data-controller~='service-status-polling']")
    expect(polling_root).to have_content(I18n.t("admin.dashboard.external_services.upload_blocked"))

    page.execute_script(<<~JAVASCRIPT)
      document
        .querySelector('[data-service-status-polling-target="serviceStatusCard"]')
        .firstElementChild
        .dataset.beforeRefresh = 'true'
    JAVASCRIPT
    ENV["RECEIPT_OCR_ENABLED"] = "true"
    ENV["RECEIPT_AI_ENABLED"] = "true"

    within(polling_root) do
      click_button I18n.t("admin.dashboard.external_services.refresh")
    end

    expect(page).to have_no_css("[data-before-refresh='true']")
    expect(polling_root).to have_content(I18n.t("admin.dashboard.external_services.upload_allowed"))
    expect(page).to have_current_path(admin_root_path)
    expect_browser_console_clean
  end

  it "mobile幅で主要dashboardを横overflowなしに表示する", mobile: true do
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: true
    )
    admin = create_system_test_user(admin: true)

    sign_in_through_browser(admin)
    visit admin_root_path

    expect(page).to have_content(I18n.t("admin.dashboard.title"))
    expect(page.evaluate_script("window.innerWidth")).to eq(390)
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    expect_browser_console_clean
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
