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

  def with_mobile_viewport
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: true
    )
    yield
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
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

  it "lowercase表示IDと通常tokenを検索しURL・戻る・clear・最新入力を同期する" do
    user = create_system_test_user
    target = create(
      :receipt,
      :completed,
      user: user,
      store_name: "青空スーパー",
      total_amount: 100,
      display_id: "R-BRWS01"
    )
    text_only = create(
      :receipt,
      :completed,
      user: user,
      store_name: "青空スーパー",
      memo: "参照 R-BRWS01",
      total_amount: 200,
      display_id: "R-BRWS02"
    )
    other = create(
      :receipt,
      :completed,
      user: user,
      store_name: "別の店",
      total_amount: 300,
      display_id: "R-BRWS03"
    )
    raw_query = "r-brws01 青空スーパー"

    sign_in_through_browser(user)
    wait_for_stimulus_controller("search")
    search_input = find("[data-search-query-input]", visible: true, match: :first)
    search_input.set(raw_query)

    expect(page).to have_current_path(receipts_path(q: raw_query))
    expect(receipt_card_ids).to contain_exactly(target.public_id)
    expect(page).to have_no_css(
      "#receipts-list-grid [data-receipt-card-public-id='#{text_only.public_id}']"
    )

    search_input.send_keys(:escape)
    expect(page).to have_css("#desktop-search-help.hidden", visible: :all)

    find(
      "#receipt_#{target.public_id} a[href='#{receipt_path(target, from: "index")}']",
      match: :first
    ).click
    expect(page).to have_current_path(receipt_path(target, from: "index"))

    page.go_back

    expect(page).to have_current_path(receipts_path(q: raw_query))
    expect(page).to have_field("q", with: raw_query, visible: true)
    expect(receipt_card_ids).to contain_exactly(target.public_id)

    search_input = find("[data-search-query-input]", visible: true, match: :first)
    stale_response_script = <<~JAVASCRIPT
      const input = arguments[0]
      const firstQuery = arguments[1]
      const finalQuery = arguments[2]
      const done = arguments[arguments.length - 1]
      const originalFetch = window.fetch

      window.fetch = (...args) => {
        const response = originalFetch.apply(window, args)
        const requestUrl = String(args[0])
        if (!requestUrl.includes(encodeURIComponent(firstQuery))) return response

        return response.then((value) => new Promise((resolve) => {
          window.setTimeout(() => resolve(value), 800)
        }))
      }

      const setQuery = (value) => {
        input.value = value
        input.dispatchEvent(new Event("input", { bubbles: true }))
      }

      setQuery(firstQuery)
      window.setTimeout(() => setQuery(finalQuery), 350)
      window.setTimeout(() => {
        window.fetch = originalFetch
        done(true)
      }, 1400)
    JAVASCRIPT
    stale_response_exercised = page.evaluate_async_script(
      stale_response_script,
      search_input.native,
      other.display_id,
      target.display_id.downcase
    )

    expect(stale_response_exercised).to be(true)
    expect(page).to have_current_path(receipts_path(q: target.display_id.downcase))
    expect(receipt_card_ids).to contain_exactly(target.public_id)

    search_input.set("")

    expect(page).to have_current_path(receipts_path)
    expect(receipt_card_ids).to contain_exactly(target.public_id, text_only.public_id, other.public_id)
    expect_browser_console_clean
  end

  it "390pxのmobile overlayから表示ID検索・help・結果遷移・戻るを操作できる", :mobile do
    user = create_system_test_user
    target = create(
      :receipt,
      :completed,
      user: user,
      store_name: "モバイル対象店",
      total_amount: 100,
      display_id: "R-MOB001"
    )
    create(
      :receipt,
      :completed,
      user: user,
      store_name: "モバイル別店",
      total_amount: 200,
      display_id: "R-MOB002"
    )
    raw_query = target.display_id.downcase

    with_mobile_viewport do
      sign_in_through_browser(user)
      wait_for_stimulus_controller("search")
      toggle = find("button[data-search-target='toggle']")
      toggle.click

      expect(toggle["aria-expanded"]).to eq("true")
      expect(page).to have_css("#mobile-search-panel", visible: true)

      mobile_input = find("#mobile-search-panel [data-search-query-input]", visible: true)
      mobile_input.click
      expect(page).to have_css(
        "#mobile-search-help",
        visible: true,
        text: "表示ID（R-XXXXXX）は完全一致で検索できます。"
      )

      mobile_input.set(raw_query)

      expect(page).to have_current_path(receipts_path(q: raw_query))
      expect(receipt_card_ids).to contain_exactly(target.public_id)
      aggregate_failures do
        expect(page.evaluate_script("window.innerWidth")).to eq(390)
        expect(page.evaluate_script("document.documentElement.scrollWidth")).to be <= 390
        expect(mobile_input["aria-describedby"]).to eq("mobile-search-help")
      end

      page.send_keys(:escape)
      expect(page).to have_css("#mobile-search-panel.hidden", visible: :all)
      expect(toggle["aria-expanded"]).to eq("false")

      find(
        "#receipt_#{target.public_id} a[href='#{receipt_path(target, from: "index")}']",
        match: :first
      ).click
      expect(page).to have_current_path(receipt_path(target, from: "index"))

      page.go_back

      expect(page).to have_current_path(receipts_path(q: raw_query))
      expect(receipt_card_ids).to contain_exactly(target.public_id)
      expect(page).to have_field("q", with: raw_query, visible: :all)
      expect_browser_console_clean
    end
  end
end
