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
end
