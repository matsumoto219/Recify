require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "レシート一覧の実Chrome検索と並び替え", type: :system do
  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  def receipt_card_ids
    all("#receipts-list-grid [data-receipt-card-public-id]").map do |node|
      node["data-receipt-card-public-id"]
    end
  end

  def expect_only_invalid_search_response_in_browser_console
    severe_entries = page.driver.browser.logs.get(:browser).select do |entry|
      entry.level == "SEVERE" && !blocked_external_font_entry?(entry)
    end
    validation_entries, unexpected_entries = severe_entries.partition do |entry|
      entry.message.include?("/receipts?q=date%3E%3D2026-99-99") &&
        entry.message.include?("422 (Unprocessable Content)")
    end

    aggregate_failures do
      expect(validation_entries.size).to eq(1)
      expect(unexpected_entries).to be_empty
    end
  end

  it "search結果をDOMとURLへ反映し、不正queryでは既存結果を維持する" do
    user = create_system_test_user
    matching_receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "コーヒー店",
      total_amount: 100,
      purchased_at: Time.zone.local(2026, 7, 12, 10, 0, 0)
    )
    other_receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "食品店",
      total_amount: 500,
      purchased_at: Time.zone.local(2026, 7, 12, 11, 0, 0)
    )

    sign_in_through_browser(user)
    wait_for_stimulus_controller("search")
    search_input = find("[data-search-query-input]", visible: true, match: :first)
    search_input.set("コーヒー")

    expect(page).to have_current_path(receipts_path(q: "コーヒー"))
    expect(page).to have_css(
      "#receipts-list-grid [data-receipt-card-public-id='#{matching_receipt.public_id}']"
    )
    expect(page).to have_no_css(
      "#receipts-list-grid [data-receipt-card-public-id='#{other_receipt.public_id}']"
    )

    search_input.set("date>=2026-99-99")

    expect(page).to have_css("#search-error-toast", text: I18n.t("search.realtime.invalid_query_message"))
    expect(page).to have_css(
      "#receipts-list-grid [data-receipt-card-public-id='#{matching_receipt.public_id}']"
    )
    expect(page).to have_no_css(
      "#receipts-list-grid [data-receipt-card-public-id='#{other_receipt.public_id}']"
    )
    expect(page).to have_current_path(receipts_path(q: "コーヒー"))

    search_input.set("")

    expect(page).to have_current_path(receipts_path)
    expect(page).to have_no_css("#search-error-toast")
    expect(receipt_card_ids).to contain_exactly(matching_receipt.public_id, other_receipt.public_id)
    expect_only_invalid_search_response_in_browser_console
  end

  it "金額降順を実form submitで反映する" do
    user = create_system_test_user
    lower = create(:receipt, :completed, user: user, store_name: "少額店", total_amount: 100)
    higher = create(:receipt, :completed, user: user, store_name: "高額店", total_amount: 500)

    sign_in_through_browser(user)
    sort_control = find("#receipts-sort-control")
    sort_control.select(I18n.t("receipts.index.controls.sort_options.amount_desc"))
    page.execute_script(
      "arguments[0].dispatchEvent(new Event('change', { bubbles: true }))",
      sort_control.native
    )

    expect(page).to have_current_path(%r{\A/receipts\?})
    expect(page).to have_css("#receipts-sort-control option[value='amount_desc']:checked")
    ids = receipt_card_ids
    expect(ids.index(higher.public_id)).to be < ids.index(lower.public_id)
    expect(Rack::Utils.parse_query(URI.parse(page.current_url).query)).to include(
      "sort" => "amount_desc",
      "per_page" => "20"
    )
    expect_browser_console_clean
  end

  it "購入日時順を検索条件とURLへ保持し、両方向でnilを末尾にする" do
    user = create_system_test_user
    common_name = "購入日時ブラウザ"
    older = create(
      :receipt,
      :completed,
      user:,
      store_name: common_name,
      purchased_at: Time.zone.local(2026, 7, 10, 9, 0)
    )
    newer = create(
      :receipt,
      :completed,
      user:,
      store_name: common_name,
      purchased_at: Time.zone.local(2026, 7, 12, 15, 0)
    )
    nil_purchased_at = create(:receipt, :completed, user:, store_name: common_name)
    nil_purchased_at.update_column(:purchased_at, nil)

    sign_in_through_browser(user)
    wait_for_stimulus_controller("search")
    search_input = find("[data-search-query-input]", visible: true, match: :first)
    search_input.set(common_name)
    expect(page).to have_current_path(receipts_path(q: common_name))

    sort_control = find("#receipts-sort-control")
    sort_control.select(I18n.t("receipts.index.controls.sort_options.purchased_at_desc"))
    page.execute_script(
      "arguments[0].dispatchEvent(new Event('change', { bubbles: true }))",
      sort_control.native
    )

    expect(page).to have_current_path(%r{\A/receipts\?.*sort=purchased_at_desc})
    expect(page).to have_css("#receipts-sort-control option[value='purchased_at_desc']:checked")
    expect(receipt_card_ids).to eq([ newer.public_id, older.public_id, nil_purchased_at.public_id ])
    expect(Rack::Utils.parse_query(URI.parse(page.current_url).query)).to include(
      "q" => common_name,
      "sort" => "purchased_at_desc"
    )

    sort_control = find("#receipts-sort-control")
    sort_control.select(I18n.t("receipts.index.controls.sort_options.purchased_at_asc"))
    page.execute_script(
      "arguments[0].dispatchEvent(new Event('change', { bubbles: true }))",
      sort_control.native
    )

    expect(page).to have_current_path(%r{\A/receipts\?.*sort=purchased_at_asc})
    expect(page).to have_css("#receipts-sort-control option[value='purchased_at_asc']:checked")
    expect(receipt_card_ids).to eq([ older.public_id, newer.public_id, nil_purchased_at.public_id ])

    page.go_back

    expect(page).to have_current_path(%r{\A/receipts\?.*sort=purchased_at_desc})
    expect(find("#receipts-sort-control").value).to eq("purchased_at_desc")
    expect(receipt_card_ids).to eq([ newer.public_id, older.public_id, nil_purchased_at.public_id ])
    expect_browser_console_clean
  end

  it "390pxでも購入日時sortを選択でき、横overflowを起こさない", :mobile do
    user = create_system_test_user
    older = create(
      :receipt,
      :completed,
      user:,
      purchased_at: Time.zone.local(2026, 7, 10, 9, 0)
    )
    newer = create(
      :receipt,
      :completed,
      user:,
      purchased_at: Time.zone.local(2026, 7, 12, 15, 0)
    )

    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: true
    )
    sign_in_through_browser(user)
    sort_control = find("#receipts-sort-control")

    aggregate_failures do
      expect(sort_control["aria-label"]).to eq(I18n.t("receipts.index.controls.sort_label"))
      expect(page.evaluate_script("window.innerWidth")).to eq(390)
      expect(page.evaluate_script("document.documentElement.scrollWidth")).to eq(390)
    end

    sort_control.select(I18n.t("receipts.index.controls.sort_options.purchased_at_desc"))
    page.execute_script(
      "arguments[0].dispatchEvent(new Event('change', { bubbles: true }))",
      sort_control.native
    )

    expect(page).to have_current_path(%r{\A/receipts\?.*sort=purchased_at_desc})
    expect(receipt_card_ids.index(newer.public_id)).to be < receipt_card_ids.index(older.public_id)
    expect(page.evaluate_script("document.documentElement.scrollWidth")).to eq(390)
    expect_browser_console_clean
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
