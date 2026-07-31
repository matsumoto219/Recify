require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "管理者のReceipt ID検索", type: :system do
  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  def current_query
    Rack::Utils.parse_nested_query(URI.parse(page.current_url).query)
  end

  it "display/public ID、衝突、user絞り込み、pagination、browser backを維持する" do
    admin = create_system_test_user(admin: true)
    first_user = create(:user)
    second_user = create(:user)
    first_receipt = create(
      :receipt,
      user: first_user,
      display_id: "R-ABC123",
      public_id: "rcpt_Aa11Bb22Cc33Dd44"
    )
    second_receipt = create(
      :receipt,
      user: second_user,
      display_id: "R-ABC123",
      public_id: "rcpt_Ee55Ff66Gg77Hh88"
    )
    first_runs = create_list(:receipt_analysis_run, 26, :succeeded, receipt: first_receipt)
    second_runs = create_list(:receipt_analysis_run, 2, :failed, receipt: second_receipt)

    sign_in_through_browser(admin)
    visit admin_receipt_analysis_runs_path
    fill_in "receipt_public_id", with: "r-abc123"
    click_button I18n.t("admin.receipt_analysis_runs.index.filters.submit")

    expect(page).to have_current_path(%r{\A/admin/receipt_analysis_runs\?.*receipt_public_id=r-abc123})

    aggregate_failures do
      expect(current_query).to include("receipt_public_id" => "r-abc123")
      (first_runs + second_runs).each { |run| expect(page).to have_content(run.run_key) }
      expect(page).to have_content(first_receipt.public_id)
      expect(page).to have_content(second_receipt.public_id)
    end

    fill_in "user_id", with: first_user.id
    select "25件", from: "limit"
    click_button I18n.t("admin.receipt_analysis_runs.index.filters.submit")

    expect(page).to have_content("26件中 1-25件を表示")

    aggregate_failures do
      expect(current_query).to include(
        "receipt_public_id" => "r-abc123",
        "user_id" => first_user.id.to_s,
        "limit" => "25"
      )
      expect(page).to have_content("26件中 1-25件を表示")
      expect(page).to have_content(first_runs.last.run_key)
      second_runs.each { |run| expect(page).to have_no_content(run.run_key) }
    end

    visible_run = first_runs.min_by(&:id)
    click_link I18n.t("admin.receipt_analysis_runs.index.results.next")
    expect(page).to have_content(visible_run.run_key)
    expect(current_query).to include(
      "receipt_public_id" => "r-abc123",
      "user_id" => first_user.id.to_s,
      "limit" => "25",
      "offset" => "25"
    )

    click_link visible_run.run_key
    expect(page).to have_current_path(admin_receipt_analysis_run_path(visible_run.run_key), ignore_query: true)
    page.go_back

    aggregate_failures do
      expect(page).to have_field("receipt_public_id", with: "r-abc123")
      expect(current_query).to include("offset" => "25")
      expect(page).to have_content(visible_run.run_key)
    end

    fill_in "receipt_public_id", with: second_receipt.public_id
    fill_in "user_id", with: ""
    select "25件", from: "limit"
    click_button I18n.t("admin.receipt_analysis_runs.index.filters.submit")

    expect(page).to have_content(second_runs.last.run_key)

    aggregate_failures do
      second_runs.each { |run| expect(page).to have_content(run.run_key) }
      first_runs.each { |run| expect(page).to have_no_content(run.run_key) }
    end

    fill_in "receipt_public_id", with: "R-ABC"
    click_button I18n.t("admin.receipt_analysis_runs.index.filters.submit")
    expect(page).to have_content(I18n.t("admin.receipt_analysis_runs.index.results.empty"))

    click_link I18n.t("admin.receipt_analysis_runs.index.filters.clear")
    expect(page).to have_content("28件中 1-28件を表示")
    aggregate_failures do
      expect(page).to have_field("receipt_public_id", with: "")
      (first_runs + second_runs).each { |run| expect(page).to have_content(run.run_key) }
    end
    expect_browser_console_clean
  end

  it "390pxでkeyboard検索を横overflowなしに表示する", :mobile do
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: true
    )
    admin = create_system_test_user(admin: true)
    receipt = create(:receipt, display_id: "R-ABC123")
    run = create(:receipt_analysis_run, :succeeded, receipt:)

    sign_in_through_browser(admin)
    visit admin_receipt_analysis_runs_path

    field = find_field("receipt_public_id")
    field.fill_in(with: "r-abc123")
    field.send_keys(:enter)

    aggregate_failures do
      expect(page).to have_content(run.run_key)
      expect(page).to have_field("receipt_public_id", with: "r-abc123")
      expect(page.evaluate_script("window.innerWidth")).to eq(390)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    end
    expect_browser_console_clean
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
