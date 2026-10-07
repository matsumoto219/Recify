require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "レシート固有の計算条件", type: :system do
  it "税区分未確定の金額編集が422になった直後は保存済み合計をプレビューや支払同期に使わない" do
    user = create_system_test_user(password: "password")
    receipt = create(
      :receipt,
      :completed,
      user: user,
      subtotal_amount: 200,
      tax_amount: 20,
      total_amount: 220,
      payment_method: "cash",
      calculation_settings: {
        "schema_version" => 1,
        "tax_rounding_mode" => { "value" => "floor", "origin" => "analysis" },
        "discount_rounding_mode" => { "value" => "round", "origin" => "analysis" },
        "tax_rounding_scope" => { "value" => "per_tax_rate_group", "origin" => "analysis" }
      }
    )
    item = receipt.receipt_items.create!(
      confirmed_name: "税区分未確定品",
      pricing_source_kind: "count_unit_price",
      price: 100,
      quantity: 2,
      quantity_unit_code: "each",
      tax_rate: BigDecimal("0.1"),
      original_line_total: 200,
      line_total: 200
    )
    tax_detail = receipt.receipt_tax_details.create!(
      description: "外税10%",
      net_amount: 200,
      amount: 20,
      rate: BigDecimal("0.1")
    )
    payment = receipt.receipt_payments.create!(method: "現金", amount: 200)
    saved_records = [ receipt, item, tax_detail, payment ].map(&:attributes)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")

    expect(page).to have_css('[data-receipt-form-target="totalAmount"]', text: "220")
    row = find('[data-receipt-form-target="itemRow"]', match: :first)
    row.find('[data-receipt-form-target="quantityInput"]', visible: :all).set("3")
    selected_tax_inclusion = row.find('[data-receipt-form-target="itemTaxInclusionControl"] input:checked', visible: :all)
    page.execute_script("arguments[0].value = ''", selected_tax_inclusion)
    click_button I18n.t("receipts.form.buttons.save"), match: :first

    error_summary = find('[data-receipt-form-target="invalidItemSourceSummary"]', visible: true)
    expect(error_summary).to have_text(I18n.t("receipts.form.errors.invalid_item_pricing_source"))
    wait_for_stimulus_controller("receipt-form")
    notice = find('[data-receipt-form-target="previewUnavailableNotice"]', visible: true)
    row = find('[data-receipt-form-target="itemRow"]', match: :first)
    aggregate_failures do
      expect(row.find('[data-receipt-form-target="quantityInput"]', visible: :all).value).to eq("3")
      expect(row).to have_no_css('[data-receipt-form-target="itemTaxInclusionControl"] input:checked', visible: :all)
      expect(notice).to have_text(I18n.t("receipts.form.amount_summary.preview_unavailable"))
      expect(notice).to have_text(I18n.t("receipts.form.amount_summary.saved_total", amount: "¥220"))
      %w[totalAmount subtotalAmount taxAmount paymentReconciliationFinalAmount paymentDifferenceAmount].each do |target|
        expect(find("[data-receipt-form-target='#{target}']", visible: :all)).to have_text(
          I18n.t("receipts.common.not_available"), exact: true
        )
      end
      expect(page).to have_no_css('[data-receipt-form-target="syncPaymentAmountButton"]', visible: true)
      expect(page).to have_no_css('[data-receipt-form-target="paymentMismatchWarning"]', visible: true)
      expect(find('[data-receipt-form-target="paymentAmountInput"]', visible: :all).value).to eq("200")
      expect([ receipt, item, tax_detail, payment ].map { |record| record.reload.attributes }).to eq(saved_records)
    end
    severe_entries = page.driver.browser.logs.get(:browser).select do |entry|
      entry.level == "SEVERE" && !blocked_external_font_entry?(entry)
    end
    validation_entries, unexpected_entries = severe_entries.partition do |entry|
      entry.message.include?(receipt_path(receipt)) && entry.message.include?("422 (Unprocessable Content)")
    end
    expect(validation_entries.size).to eq(1)
    expect(unexpected_entries).to be_empty
  end

  it "解析保存した混在明細の税区分と元金額を編集開始・無変更保存で維持する" do
    user = create_system_test_user(password: "password", default_item_tax_inclusion: "net")
    receipt = create(
      :receipt,
      :completed,
      user: user,
      subtotal_amount: 500,
      tax_amount: 50,
      total_amount: 550,
      payment_method: "cash",
      calculation_settings: {
        "schema_version" => 1,
        "tax_rounding_mode" => { "value" => "floor", "origin" => "analysis" },
        "discount_rounding_mode" => { "value" => "round", "origin" => "analysis" },
        "tax_rounding_scope" => { "value" => "per_tax_rate_group", "origin" => "analysis" }
      }
    )
    items = [ [ "net", 300, 330 ], [ "gross", 220, 220 ] ].each_with_index.map do |(basis, source, gross), index|
      receipt.receipt_items.create!(
        confirmed_name: "混在確認品#{index + 1}",
        position_index: index,
        pricing_source_kind: "explicit_line_total",
        quantity: 1,
        quantity_unit_code: "each",
        tax_rate: BigDecimal("0.1"),
        original_line_total: source,
        line_total: source,
        gross_line_total: gross,
        input_tax_inclusion: basis,
        tax_inclusion_origin: "analysis"
      )
    end
    source_fields = %w[original_line_total line_total gross_line_total input_tax_inclusion tax_inclusion_origin]
    before_sources = items.map { |item| item.attributes.slice(*source_fields) }
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)

    2.times do
      visit edit_receipt_path(receipt)
      wait_for_stimulus_controller("receipt-form")
      items.zip(%w[net gross]) do |item, basis|
        row = find("##{ReceiptsHelper::RECEIPT_REVIEW_TARGET_ITEM_ID_PREFIX}#{item.id}")
        expect(row).to have_css(
          "[data-receipt-form-target='itemTaxInclusionControl'] input[value='#{basis}']:checked",
          visible: :all
        )
      end
      expect(page).to have_css('[data-receipt-form-target="totalAmount"]', text: "550")
      click_button I18n.t("receipts.form.buttons.save"), match: :first
      expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
      expect(receipt.reload.total_amount).to eq(550)
      expect(items.map { |item| item.reload.attributes.slice(*source_fields) }).to eq(before_sources)
    end
    expect_browser_console_clean
  end

  it "保存済み条件を維持し、税込と税抜の切替では単価を換算せず保存する" do
    user = create_system_test_user(password: "password", tax_rounding_mode: "ceil", default_item_tax_inclusion: "net")
    settings = {
      "schema_version" => 1,
      "tax_rounding_mode" => { "value" => "floor", "origin" => "manual" },
      "discount_rounding_mode" => { "value" => "round", "origin" => "manual" },
      "tax_rounding_scope" => { "value" => "per_tax_rate_group", "origin" => "application_default" }
    }
    receipt = create(
      :receipt,
      :completed,
      user: user,
      calculation_settings: settings,
      subtotal_amount: 200,
      tax_amount: 20,
      total_amount: 220,
      payment_method: "cash"
    )
    item = receipt.receipt_items.create!(
      confirmed_name: "税区分切替品",
      pricing_source_kind: "count_unit_price",
      price: 100,
      quantity: 2,
      quantity_unit_code: "each",
      tax_rate: BigDecimal("0.1"),
      original_line_total: 200,
      line_total: 200,
      gross_line_total: 220,
      input_tax_inclusion: "net",
      tax_inclusion_origin: "manual"
    )
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")

    expect(page).to have_css('input[name="receipt_calculation_settings[tax_rounding_mode]"][value="floor"]:checked', visible: :all)
    expect(page).to have_css('[data-receipt-form-target="totalAmount"]', text: "220")
    payment_heading = find("##{ReceiptsHelper::RECEIPT_REVIEW_TARGET_PAYMENTS} h2")
    calculation_heading = find("h2", text: "レシート計算方式", exact_text: true)
    memo_heading = find(".receipt-form-memo-card h2")
    headings_in_order = page.evaluate_script(<<~JAVASCRIPT, payment_heading, calculation_heading, memo_heading)
      Boolean(arguments[0].compareDocumentPosition(arguments[1]) & Node.DOCUMENT_POSITION_FOLLOWING) &&
        Boolean(arguments[1].compareDocumentPosition(arguments[2]) & Node.DOCUMENT_POSITION_FOLLOWING)
    JAVASCRIPT
    expect(headings_in_order).to be(true)

    wait_for_stimulus_controller("tip")
    expect(page).to have_no_css('[data-tip-target="panel"]', visible: true)
    tip_trigger = find_button("合計金額の補足")
    tip_trigger.hover
    expect(page).to have_css('[data-tip-target="panel"]', text: I18n.t("receipts.show.official_total_note"))
    tip_trigger.send_keys(:escape)
    expect(page).to have_no_css('[data-tip-target="panel"]', visible: true)
    tip_trigger.click
    expect(page).to have_css('[data-tip-target="panel"]', text: I18n.t("receipts.show.official_total_note"))
    find("h2", text: I18n.t("receipts.form.sections.basic_info"), exact_text: true).click
    expect(page).to have_no_css('[data-tip-target="panel"]', visible: true)
    row = find('[data-receipt-form-target="itemRow"]', match: :first)
    row.find('[data-receipt-form-target="itemDetailsToggle"]', visible: true, match: :first).click
    row.find('summary[data-receipt-pricing-source-summary]', visible: true).click
    control = row.find('[data-receipt-form-target="itemTaxInclusionControl"]', visible: true)
    control.find('label', text: "税込", exact_text: true).click

    expect(page).to have_css('[data-receipt-form-target="totalAmount"]', text: "200")
    expect(row.find('[data-receipt-form-target="priceInput"]').value).to eq("100")
    expect(row.find('[data-receipt-form-target="quantityInput"]').value).to eq("2")
    click_button I18n.t("receipts.form.buttons.save"), match: :first
    expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
    expect(item.reload.attributes).to include(
      "price" => 100, "line_total" => 200, "gross_line_total" => 200, "input_tax_inclusion" => "gross"
    )
    expect(receipt.reload.total_amount).to eq(200)
    expect(receipt.calculation_settings.slice("tax_rounding_mode", "discount_rounding_mode")).to eq(
      settings.slice("tax_rounding_mode", "discount_rounding_mode")
    )
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    expect(page).to have_css('[data-receipt-form-target="itemTaxInclusionControl"] input[value="gross"]:checked', visible: :all)
    user.update!(default_item_tax_inclusion: "gross")
    click_button I18n.t("receipts.form.buttons.add_item")
    added_row = all('[data-receipt-form-target="itemRow"]', visible: :all).last
    expect(added_row).to have_css('[data-receipt-form-target="itemTaxInclusionControl"] input[value="net"]:checked', visible: :all)
    expect(item.reload.input_tax_inclusion).to eq("gross")
    expect_browser_console_clean
  end

  it "主入力がタッチ扱いでも実際のマウスホバーで合計金額の補足を開ける" do
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 1)
    user = create_system_test_user(password: "password")
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
    visit new_receipt_path
    wait_for_stimulus_controller("receipt-form")
    wait_for_stimulus_controller("tip")
    expect(page.evaluate_script("window.matchMedia('(hover: hover)').matches")).to be(false)
    expect(page).to have_no_css('[data-tip-target="panel"]', visible: true)

    find_button("合計金額の補足").hover
    expect(page).to have_css('[data-tip-target="panel"]', text: I18n.t("receipts.show.official_total_note"))
    expect_browser_console_clean
  ensure
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
  end

  it "詳細と編集を戻る・進むで往復しても合計金額の補足を開ける" do
    user = create_system_test_user(password: "password")
    receipt = create(
      :receipt,
      :completed,
      user: user,
      subtotal_amount: 100,
      tax_amount: 0,
      total_amount: 100,
      payment_method: "cash"
    )
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
    visit receipt_path(receipt)
    wait_for_stimulus_controller("tip")
    click_button "合計金額の補足"
    expect(page).to have_css('[data-tip-target="panel"]', text: I18n.t("receipts.show.official_total_note"))

    click_link I18n.t("common.edit"), match: :first
    expect(page).to have_current_path(edit_receipt_path(receipt), ignore_query: true)
    wait_for_stimulus_controller("receipt-form")
    expect(page).to have_css('[data-tip-target="panel"]', count: 1, visible: :all)

    page.go_back
    expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
    wait_for_stimulus_controller("tip")
    expect(page).to have_css('[data-tip-target="panel"]', count: 1, visible: :all)
    click_button "合計金額の補足"
    expect(page).to have_css('[data-tip-target="panel"]', text: I18n.t("receipts.show.official_total_note"))

    page.go_forward
    expect(page).to have_current_path(edit_receipt_path(receipt), ignore_query: true)
    wait_for_stimulus_controller("receipt-form")
    wait_for_stimulus_controller("tip")
    expect(page).to have_css('[data-tip-target="panel"]', count: 1, visible: :all)
    click_button "合計金額の補足"
    expect(page).to have_css('[data-tip-target="panel"]', text: I18n.t("receipts.show.official_total_note"))
    expect_browser_console_clean
  end

  it "390pxでは合計金額の補足をタップで開き、画面内に表示して閉じられる", mobile: true do
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: true
    )
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 1)
    user = create_system_test_user(password: "password")
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
    visit new_receipt_path
    wait_for_stimulus_controller("receipt-form")
    wait_for_stimulus_controller("tip")
    wait_for_stimulus_controller("mobile-amount-summary")
    expect(page).to have_css('[data-mobile-amount-summary-enhanced="true"]')
    expect(page).to have_no_css('[data-tip-target="panel"]', visible: true)

    trigger = find_button("合計金額の補足")
    geometry = page.evaluate_async_script(<<~JAVASCRIPT, trigger, Capybara.default_max_wait_time * 1000)
      const target = arguments[0]
      const timeoutMilliseconds = arguments[1]
      const done = arguments[arguments.length - 1]
      let completed = false
      const finish = (result) => {
        if (completed) return

        completed = true
        done(result)
      }

      window.setTimeout(() => finish(null), timeoutMilliseconds)
      window.requestAnimationFrame(() => {
        window.requestAnimationFrame(() => {
          const summary = target.closest('[data-mobile-amount-summary-enhanced="true"]')
          const animations = summary.getAnimations({ subtree: true })
          Promise.all([
            document.fonts?.ready || Promise.resolve(),
            ...animations.map((animation) => animation.finished.catch(() => undefined))
          ]).then(() => {
            window.requestAnimationFrame(() => {
              const rect = target.getBoundingClientRect()
              const point = { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 }
              finish({ point, hitsTrigger: target.contains(document.elementFromPoint(point.x, point.y)) })
            })
          })
        })
      })
    JAVASCRIPT
    expect(geometry).not_to be_nil, "Amount summary motion did not finish"
    expect(geometry.fetch("hitsTrigger")).to be(true)
    point = geometry.fetch("point")
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart", touchPoints: [ point ])
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchEnd", touchPoints: [])
    panel = find('[data-tip-target="panel"]', text: I18n.t("receipts.show.official_total_note"))
    panel_within_viewport = page.evaluate_script(<<~JAVASCRIPT, panel)
      (() => {
        const rect = arguments[0].getBoundingClientRect()
        return rect.left >= 0 && rect.right <= window.innerWidth &&
          rect.top >= 0 && rect.bottom <= window.innerHeight
      })()
    JAVASCRIPT
    expect(panel_within_viewport).to be(true)
    panel.find_button(I18n.t("shared.tip.close_label")).click
    expect(page).to have_no_css('[data-tip-target="panel"]', visible: true)
    expect_browser_console_clean
  ensure
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
