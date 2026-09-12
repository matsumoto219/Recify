require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "明細の金額計算方式", type: :system, mobile: true do
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

  def create_editable_receipt(user:, store_name:)
    create(
      :receipt,
      :completed,
      user: user,
      store_name: store_name,
      purchased_at: Time.zone.local(2026, 8, 13, 12, 0, 0),
      payment_method: "cash",
      subtotal_amount: 100,
      tax_amount: 0,
      total_amount: 100,
      review_reasons: []
    ).tap do |receipt|
      receipt.receipt_items.create!(
        confirmed_name: "既存商品",
        price: 100,
        quantity: 1,
        quantity_unit_code: "each",
        tax_rate: 0,
        original_line_total: 100,
        line_total: 100,
        pricing_source_kind: "count_unit_price",
        needs_review: false,
        review_reasons: []
      )
    end
  end

  def item_row_named(name)
    all("[data-receipt-form-target='itemRow']", visible: :all).find do |row|
      row.find("input[name$='[confirmed_name]']", visible: :all).value == name
    end || raise("Receipt item row not found: #{name}")
  end

  def expand_item_row(row)
    toggle = row.find("[data-receipt-form-target='itemDetailsToggle']", visible: true, match: :first)
    panel = row.find("[data-receipt-form-target='itemDetailsPanel']", visible: :all)
    toggle.click unless toggle["aria-expanded"] == "true"

    aggregate_failures do
      expect(toggle["aria-expanded"]).to eq("true")
      expect(toggle["aria-controls"]).to eq(panel[:id])
      expect(panel["aria-hidden"]).to eq("false")
      expect(page.evaluate_script("arguments[0].inert", panel)).to be(false)
    end

    row
  end

  def collapse_item_row(row)
    toggle = row.find("[data-receipt-form-target='itemDetailsToggle']", visible: true, match: :first)
    panel = row.find("[data-receipt-form-target='itemDetailsPanel']", visible: :all)
    toggle.click if toggle["aria-expanded"] == "true"

    aggregate_failures do
      expect(toggle["aria-expanded"]).to eq("false")
      expect(toggle["aria-controls"]).to eq(panel[:id])
      expect(panel["aria-hidden"]).to eq("true")
      expect(page.evaluate_script("arguments[0].inert", panel)).to be(true)
    end

    row
  end

  def pricing_source_details(row)
    row.find("details[data-receipt-pricing-source-details]", visible: :all)
  end

  def expand_pricing_source_details(row)
    details = pricing_source_details(row)
    unless details["data-collapsible-open"] == "true"
      summary = details.find("summary[data-receipt-pricing-source-summary]", visible: true)
      summary.scroll_to(:center)
      summary.click
    end

    expect(row).to have_css(
      "details[data-receipt-pricing-source-details][data-collapsible-open='true']",
      visible: :all
    )
    expect(page.evaluate_script("arguments[0].open", details)).to be(true)
    expect(details["data-collapsible-open"]).to eq("true")
    content = details.find("[data-collapsible-details-target='content']", visible: :all)
    expect(content["aria-hidden"]).to eq("false")
    expect(page.evaluate_script("arguments[0].inert", content)).to be(false)

    details
  end

  def collapse_pricing_source_details(row)
    details = pricing_source_details(row)
    if details["data-collapsible-open"] == "true"
      summary = details.find("summary[data-receipt-pricing-source-summary]", visible: true)
      summary.scroll_to(:center)
      summary.click
    end

    expect(row).to have_css(
      "details[data-receipt-pricing-source-details][data-collapsible-open='false']",
      visible: :all
    )
    details
  end

  def select_option(row, target:, value:)
    select = row.find("[data-receipt-form-target='#{target}']", visible: :all)
    select.find("option[value='#{value}']", visible: :all).select_option
    expect(select.value).to eq(value)
    select
  end

  def save_receipt
    page.execute_script("document.activeElement?.blur()")
    click_button I18n.t("receipts.form.buttons.save"), visible: true, match: :first
  end

  def reference_line_total_display(row)
    row.find(
      "[data-receipt-form-target='pricingModePanel']" \
      "[data-receipt-form-pricing-modes='reference_quantity_price'] " \
      "[data-receipt-form-target='lineTotalDisplay']",
      visible: true
    )
  end

  def expect_mobile_viewport_without_horizontal_overflow
    aggregate_failures do
      expect(page.evaluate_script("window.innerWidth")).to eq(390)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
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

    aggregate_failures do
      expect(validation_entries.size).to eq(1)
      expect(unexpected_entries).to be_empty
    end
  end

  def set_viewport(width:, height:, mobile:)
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: width,
      height: height,
      deviceScaleFactor: 1,
      mobile: mobile
    )
  end

  def wait_for_pricing_layout(row)
    ready = page.evaluate_async_script(<<~JAVASCRIPT, row, Capybara.default_max_wait_time * 1000)
      const row = arguments[0]
      const timeoutMilliseconds = arguments[1]
      const done = arguments[arguments.length - 1]
      const deadline = window.performance.now() + timeoutMilliseconds

      const check = () => {
        const animations = row.getAnimations({ subtree: true })
        if (animations.every((animation) => animation.playState === "finished") && document.fonts?.status !== "loading") {
          requestAnimationFrame(() => requestAnimationFrame(() => done(true)))
          return
        }
        if (window.performance.now() >= deadline) {
          done(false)
          return
        }
        window.setTimeout(check, 25)
      }

      check()
    JAVASCRIPT

    expect(ready).to be(true)
  end

  def reference_pricing_layout_metrics(row)
    amount_cell = row.find("[data-receipt-item-amount-cell]", visible: true)
    mobile_label = amount_cell.find("[data-receipt-item-mobile-amount-label]", visible: :all)
    result = amount_cell.find(".receipt-form-pricing-result", visible: true)
    pricing_details = row.find("details[data-receipt-pricing-source-details]", visible: :all)
    pricing_summary = pricing_details.find("summary[data-receipt-pricing-source-summary]", visible: true)
    tax_note = row.find("[data-receipt-reference-tax-note]", visible: true)
    tax_badge = tax_note.find("[data-receipt-reference-tax-badge]", visible: true)
    tax_description = tax_note.find("[data-receipt-reference-tax-description]", visible: true)
    reference_price = row.find("[data-receipt-form-target='referencePriceAmountInput']", visible: true)
    reference_quantity = row.find("[data-receipt-form-target='referenceQuantityInput']", visible: true)
    reference_unit = row.find("[data-receipt-form-target='referenceQuantityUnitInput']", visible: true)
    pricing_mode = row.find("[data-receipt-form-target='pricingSourceModeInput']", visible: true)
    layout_elements = [
      amount_cell,
      mobile_label,
      result,
      pricing_details,
      pricing_summary,
      tax_note,
      tax_badge,
      tax_description,
      reference_price,
      reference_quantity,
      reference_unit,
      pricing_mode
    ]

    page.evaluate_script(
      <<~JAVASCRIPT, *layout_elements
        (() => {
          const amountCell = arguments[0]
          const mobileLabel = arguments[1]
          const result = arguments[2]
          const pricingDetails = arguments[3]
          const pricingSummary = arguments[4]
          const taxNote = arguments[5]
          const taxBadge = arguments[6]
          const taxDescription = arguments[7]
          const referencePrice = arguments[8]
          const referenceQuantity = arguments[9]
          const referenceUnit = arguments[10]
          const pricingMode = arguments[11]
          const quantityWrapper = referenceQuantity.closest(".field-control-wrapper")
          const quantityWrapperRect = quantityWrapper.getBoundingClientRect()
          const quantityRect = referenceQuantity.getBoundingClientRect()
          const unitRect = referenceUnit.getBoundingClientRect()
          const resultRect = result.getBoundingClientRect()
          const resultChildren = Array.from(result.children).map((child) => child.getBoundingClientRect())
          const unitStyle = getComputedStyle(referenceUnit)
          const pricingModeStyle = getComputedStyle(pricingMode)
          const quantityStyle = getComputedStyle(referenceQuantity)
          const priceStyle = getComputedStyle(referencePrice)
          const labelStyle = getComputedStyle(mobileLabel)
          const pricingDetailsRect = pricingDetails.getBoundingClientRect()
          const pricingSummaryRect = pricingSummary.getBoundingClientRect()
          const pricingSummaryStyle = getComputedStyle(pricingSummary)
          const taxNoteStyle = getComputedStyle(taxNote)
          const taxBadgeRect = taxBadge.getBoundingClientRect()
          const taxDescriptionRect = taxDescription.getBoundingClientRect()
          const taxDescriptionStyle = getComputedStyle(taxDescription)
          const canvas = document.createElement("canvas")
          const context = canvas.getContext("2d")
          context.font = unitStyle.font
          const longestUnitOptionWidth = Math.max(
            ...Array.from(referenceUnit.options, (option) => context.measureText(option.text).width)
          )
          const unitHorizontalPadding =
            parseFloat(unitStyle.paddingLeft) + parseFloat(unitStyle.paddingRight)
          context.font = pricingModeStyle.font
          const longestPricingModeOptionWidth = Math.max(
            ...Array.from(pricingMode.options, (option) => context.measureText(option.text).width)
          )
          const pricingModeHorizontalPadding =
            parseFloat(pricingModeStyle.paddingLeft) + parseFloat(pricingModeStyle.paddingRight)
          const pricingModeHorizontalBorder =
            parseFloat(pricingModeStyle.borderLeftWidth) + parseFloat(pricingModeStyle.borderRightWidth)
          context.font = quantityStyle.font
          const requiredQuantityContentWidth = context.measureText(referenceQuantity.max).width
          const visibleQuantityContentWidth = quantityRect.width -
            parseFloat(quantityStyle.paddingLeft) - parseFloat(quantityStyle.paddingRight)
          const priceField = referencePrice.closest(".space-y-2")

          return {
            viewportWidth: window.innerWidth,
            horizontalOverflow: document.documentElement.scrollWidth > window.innerWidth,
            mobileAmountLabelCount: amountCell.querySelectorAll("[data-receipt-item-mobile-amount-label]").length,
            mobileAmountLabelVisible:
              labelStyle.display !== "none" && mobileLabel.getClientRects().length > 0,
            resultDisplay: getComputedStyle(result).display,
            resultHeightFits: result.scrollHeight <= result.clientHeight + 1,
            resultWidthFits: result.scrollWidth <= result.clientWidth + 1,
            resultChildrenWithin:
              resultChildren.every((rect) =>
                rect.top >= resultRect.top - 1 && rect.bottom <= resultRect.bottom + 1 &&
                rect.left >= resultRect.left - 1 && rect.right <= resultRect.right + 1
              ),
            quantityInputWithinWrapper:
              quantityRect.left >= quantityWrapperRect.left - 1 &&
              quantityRect.right <= quantityWrapperRect.right + 1,
            unitSelectWithinWrapper:
              unitRect.left >= quantityWrapperRect.left - 1 &&
              unitRect.right <= quantityWrapperRect.right + 1,
            unitSelectWidth: unitRect.width,
            requiredUnitSelectWidth: longestUnitOptionWidth + unitHorizontalPadding,
            pricingModeSelectWidth: pricingMode.getBoundingClientRect().width,
            requiredPricingModeSelectWidth:
              longestPricingModeOptionWidth + pricingModeHorizontalPadding + pricingModeHorizontalBorder,
            pricingModePaddingRight: parseFloat(pricingModeStyle.paddingRight),
            unitTextAlign: unitStyle.textAlign,
            unitTextAlignLast: unitStyle.textAlignLast,
            unitOnSameLine: Math.abs(unitRect.top - quantityRect.top) < 1,
            unitBelowQuantity: unitRect.top >= quantityRect.bottom - 1,
            visibleQuantityContentWidth,
            requiredQuantityContentWidth,
            referencePriceTextAlign: priceStyle.textAlign,
            referencePriceHasCurrencyAffix: priceField.textContent.includes("¥"),
            pricingToggleBorderWidth: pricingSummaryStyle.borderTopWidth,
            pricingToggleBackground: pricingSummaryStyle.backgroundColor,
            pricingToggleDisplay: pricingSummaryStyle.display,
            pricingToggleHeight: pricingSummaryRect.height,
            pricingToggleWidth: pricingSummaryRect.width,
            pricingDetailsWidth: pricingDetailsRect.width,
            taxNoteAlignItems: taxNoteStyle.alignItems,
            taxBadgeDescriptionCenterDifference: Math.abs(
              (taxBadgeRect.top + taxBadgeRect.height / 2) -
              (taxDescriptionRect.top + taxDescriptionRect.height / 2)
            ),
            taxDescriptionLineCount: taxDescriptionRect.height / parseFloat(taxDescriptionStyle.lineHeight)
          }
        })()
      JAVASCRIPT
    )
  end

  def pricing_stepper_layout_metrics(row, input_target:, button_label:)
    input = row.find("[data-receipt-form-target='#{input_target}']", visible: true)
    wrapper = input.find(:xpath, "ancestor::*[contains(concat(' ', normalize-space(@class), ' '), ' field-control-wrapper ')][1]", visible: true)
    buttons = wrapper.all("button.field-stepper-button[aria-label*='#{button_label}']", visible: :all)

    page.evaluate_script(
      <<~JAVASCRIPT, wrapper, input, *buttons
        (() => {
          const wrapper = arguments[0]
          const input = arguments[1]
          const buttons = Array.from(arguments).slice(2)
          const wrapperRect = wrapper.getBoundingClientRect()
          const inputRect = input.getBoundingClientRect()
          const visibleButtons = buttons.filter((button) => button.getClientRects().length > 0)
          return {
            buttonCount: buttons.length,
            visibleButtonCount: visibleButtons.length,
            visibleButtonWidths: visibleButtons.map((button) => button.getBoundingClientRect().width),
            inputWithinWrapper:
              inputRect.left >= wrapperRect.left - 1 && inputRect.right <= wrapperRect.right + 1,
            buttonsWithinWrapper: visibleButtons.every((button) => {
              const rect = button.getBoundingClientRect()
              return rect.left >= wrapperRect.left - 1 && rect.right <= wrapperRect.right + 1
            })
          }
        })()
      JAVASCRIPT
    )
  end

  def visible_amount_control_height(row, mode)
    select_option(row, target: "pricingSourceModeInput", value: mode)
    amount_cell = row.find("[data-receipt-item-amount-cell]", visible: true)
    panel = amount_cell.find(
      "[data-receipt-form-target='pricingModePanel'][data-receipt-form-pricing-modes~='#{mode}']",
      visible: true
    )
    control =
      if mode == "reference_quantity_price"
        panel.find(".receipt-form-pricing-result", visible: true)
      else
        panel.find(".field-control-wrapper", visible: true)
      end

    page.evaluate_script("arguments[0].getBoundingClientRect().height", control)
  end

  it "基準価格modeを320pxからdesktopまで共通金額セル内で欠けずに表示する" do
    user = create_system_test_user
    receipt = create_editable_receipt(user: user, store_name: "基準価格レスポンシブ確認店")

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    row = expand_item_row(item_row_named("既存商品"))
    expand_pricing_source_details(row)
    collapse_pricing_source_details(row)
    expand_pricing_source_details(row)
    row.find("[data-receipt-form-target='quantityInput']", visible: true).set("1.5")
    select_option(row, target: "quantityUnitInput", value: "liter")
    select_option(row, target: "pricingSourceModeInput", value: "reference_quantity_price")
    row.find("[data-receipt-form-target='referencePriceAmountInput']", visible: true).set("120")
    row.find("[data-receipt-form-target='referenceQuantityInput']", visible: true).set("500")
    reference_unit = select_option(row, target: "referenceQuantityUnitInput", value: "milliliter")

    viewports = [
      { width: 320, height: 568, mobile: true, stacked_unit: true },
      { width: 359, height: 780, mobile: true, stacked_unit: true },
      { width: 390, height: 844, mobile: true },
      { width: 768, height: 900, mobile: false },
      { width: 1023, height: 900, mobile: false },
      { width: 1024, height: 900, mobile: false },
      { width: 1279, height: 900, mobile: false },
      { width: 1280, height: 900, mobile: false },
      { width: 1440, height: 1000, mobile: false },
      { width: 1536, height: 1000, mobile: false }
    ]

    viewports.each do |viewport|
      set_viewport(**viewport.slice(:width, :height, :mobile))
      wait_for_pricing_layout(row)
      metrics = reference_pricing_layout_metrics(row)

      aggregate_failures "viewport #{viewport.fetch(:width)}px" do
        expect(metrics.fetch("viewportWidth")).to eq(viewport.fetch(:width))
        expect(metrics.fetch("horizontalOverflow")).to be(false)
        expect(metrics.fetch("mobileAmountLabelCount")).to eq(1)
        expect(metrics.fetch("mobileAmountLabelVisible")).to be(viewport.fetch(:width) <= 767)
        expect(metrics.fetch("resultDisplay")).to eq("flex")
        expect(metrics.fetch("resultHeightFits")).to be(true)
        expect(metrics.fetch("resultWidthFits")).to be(true)
        expect(metrics.fetch("resultChildrenWithin")).to be(true)
        expect(metrics.fetch("quantityInputWithinWrapper")).to be(true)
        expect(metrics.fetch("unitSelectWithinWrapper")).to be(true)
        expect(metrics.fetch("unitSelectWidth") + 1).to be >= metrics.fetch("requiredUnitSelectWidth")
        expect(metrics.fetch("pricingModeSelectWidth") + 1).to be >=
          metrics.fetch("requiredPricingModeSelectWidth")
        expect(metrics.fetch("pricingModePaddingRight")).to be >= 40
        expect(metrics.fetch("unitTextAlign")).to eq("center")
        expect(metrics.fetch("unitTextAlignLast")).to eq("center")
        expect(metrics.fetch("visibleQuantityContentWidth") + 1).to be >=
          metrics.fetch("requiredQuantityContentWidth")
        if viewport[:stacked_unit]
          expect(metrics.fetch("unitOnSameLine")).to be(false)
          expect(metrics.fetch("unitBelowQuantity")).to be(true)
        else
          expect(metrics.fetch("unitOnSameLine")).to be(true)
        end
        expect(metrics.fetch("referencePriceTextAlign")).to eq("center")
        expect(metrics.fetch("referencePriceHasCurrencyAffix")).to be(false)
        expect(metrics.fetch("pricingToggleBorderWidth")).to eq("0px")
        expect(metrics.fetch("pricingToggleBackground")).to eq("rgba(0, 0, 0, 0)")
        expect(metrics.fetch("pricingToggleDisplay")).to eq("inline-flex")
        expect(metrics.fetch("pricingToggleHeight")).to be >= 40
        expect(metrics.fetch("pricingToggleWidth")).to be <= metrics.fetch("pricingDetailsWidth")
        expect(metrics.fetch("taxNoteAlignItems")).to eq("center")
        expect(metrics.fetch("taxBadgeDescriptionCenterDifference")).to be <= 1.5
        if viewport.fetch(:width) >= 1440
          expect(metrics.fetch("taxDescriptionLineCount")).to be <= 1.1
        end
      end
    end

    page.execute_script(<<~JAVASCRIPT, reference_unit)
      arguments[0].add(new Option("パッケージあたり", "future_long_unit", true, true))
    JAVASCRIPT
    viewports.select { |viewport| viewport.fetch(:mobile) }.each do |viewport|
      set_viewport(**viewport.slice(:width, :height, :mobile))
      wait_for_pricing_layout(row)
      metrics = reference_pricing_layout_metrics(row)

      aggregate_failures "long reference unit at #{viewport.fetch(:width)}px" do
        expect(metrics.fetch("unitSelectWidth") + 1).to be >= metrics.fetch("requiredUnitSelectWidth")
        expect(metrics.fetch("unitSelectWithinWrapper")).to be(true)
        expect(metrics.fetch("unitTextAlign")).to eq("center")
        expect(metrics.fetch("unitTextAlignLast")).to eq("center")
        expect(metrics.fetch("unitOnSameLine") || metrics.fetch("unitBelowQuantity")).to be(true)
        expect(metrics.fetch("horizontalOverflow")).to be(false)
      end
    end
    reference_unit.find("option[value='milliliter']", visible: :all).select_option

    set_viewport(width: 390, height: 844, mobile: true)
    wait_for_pricing_layout(row)
    %w[count_unit_price reference_quantity_price explicit_line_total].each do |mode|
      select_option(row, target: "pricingSourceModeInput", value: mode)
      amount_cell = row.find("[data-receipt-item-amount-cell]", visible: true)
      aggregate_failures "mobile amount label in #{mode}" do
        expect(amount_cell).to have_css("[data-receipt-item-mobile-amount-label]", count: 1, visible: true)
        expect(amount_cell.find("[data-receipt-item-mobile-amount-label]", visible: true)).to have_text(
          I18n.t("receipts.item_fields.amount")
        )
        expect(amount_cell).to have_css(
          "[data-receipt-form-target='pricingModePanel']:not([hidden])",
          count: 1,
          visible: true
        )
      end
    end

    [ 390, 768, 1440 ].each do |width|
      set_viewport(width:, height: 900, mobile: width < 768)
      wait_for_pricing_layout(row)
      amount_control_heights = %w[count_unit_price reference_quantity_price explicit_line_total].to_h do |mode|
        [ mode, visible_amount_control_height(row, mode) ]
      end
      expect(amount_control_heights.values.max - amount_control_heights.values.min).to be <= 1,
        "#{width}px: #{amount_control_heights.inspect}"
    end

    select_option(row, target: "pricingSourceModeInput", value: "reference_quantity_price")
    expect(reference_line_total_display(row)).to have_text("¥360")

    [ 320, 390, 768 ].each do |width|
      set_viewport(width:, height: 900, mobile: width < 768)
      wait_for_pricing_layout(row)
      reference_metrics = pricing_stepper_layout_metrics(
        row,
        input_target: "referencePriceAmountInput",
        button_label: I18n.t("receipts.item_fields.reference_price_amount")
      )

      select_option(row, target: "pricingSourceModeInput", value: "explicit_line_total")
      explicit_metrics = pricing_stepper_layout_metrics(
        row,
        input_target: "explicitLineTotalInput",
        button_label: I18n.t("receipts.item_fields.explicit_line_total")
      )
      select_option(row, target: "pricingSourceModeInput", value: "reference_quantity_price")

      [ reference_metrics, explicit_metrics ].each do |metrics|
        aggregate_failures "stepper at #{width}px" do
          expect(metrics.fetch("buttonCount")).to eq(2)
          expect(metrics.fetch("visibleButtonCount")).to eq(width < 768 ? 2 : 0)
          expect(metrics.fetch("visibleButtonWidths")).to all(be >= 40)
          expect(metrics.fetch("inputWithinWrapper")).to be(true)
          expect(metrics.fetch("buttonsWithinWrapper")).to be(true)
        end
      end
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    end

    set_viewport(width: 390, height: 844, mobile: true)
    expect_browser_console_clean
  end

  it "閉じた計算方式内の必須sourceが未入力なら開いて入力欄へ案内する" do
    user = create_system_test_user
    receipt = create_editable_receipt(user: user, store_name: "必須source案内店")

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    row = expand_item_row(item_row_named("既存商品"))
    expand_pricing_source_details(row)
    select_option(row, target: "pricingSourceModeInput", value: "reference_quantity_price")
    reference_price = row.find("[data-receipt-form-target='referencePriceAmountInput']", visible: true)
    reference_quantity = row.find("[data-receipt-form-target='referenceQuantityInput']", visible: true)
    reference_price.set("")
    reference_quantity.set("")
    details = collapse_pricing_source_details(row)
    collapse_item_row(row)

    save_receipt

    expect(page).to have_css(
      "details[data-receipt-pricing-source-details][data-collapsible-open='true']",
      visible: true
    )
    aggregate_failures do
      expect(page).to have_current_path(edit_receipt_path(receipt), ignore_query: true)
      expect(row.find("[data-receipt-form-target='itemDetailsToggle']", visible: true, match: :first)["aria-expanded"]).to eq("true")
      expect(page.evaluate_script("arguments[0].open", details)).to be(true)
      expect(details["data-collapsible-open"]).to eq("true")
      expect(page.evaluate_script("document.activeElement === arguments[0]", reference_price)).to be(true)
    end
    expect_browser_console_clean
  end

  it "要確認の計算方式だけを展開して強調し、同じsourceの通常保存で確認済みにする" do
    user = create_system_test_user
    receipt = create_editable_receipt(user: user, store_name: "計算方式確認店")
    item = receipt.receipt_items.sole
    item.update!(
      needs_review: true,
      review_reasons: [ "item_pricing_mode_uncertain" ]
    )
    receipt.update!(
      status: "review_needed",
      review_reasons: %w[ocr_unreadable item_pricing_mode_uncertain]
    )

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    row = item_row_named("既存商品")
    pricing_details = pricing_source_details(row)
    pricing_mode = row.find("[data-receipt-form-target='pricingSourceModeInput']", visible: true)
    quantity = row.find("[data-receipt-form-target='quantityInput']", visible: true)
    expect(row).to have_css(
      "details[data-receipt-pricing-source-details][data-collapsible-open='true']",
      visible: :all
    )

    aggregate_failures "要確認の対象controlだけを初期表示で案内する" do
      expect(row).to have_css(
        "[data-receipt-form-target='itemDetailsToggle'][aria-expanded='true']",
        count: 2,
        visible: :all
      )
      expect(row).to have_css(
        "[data-receipt-form-target='itemDetailsPanel'].is-open[aria-hidden='false']:not([inert])",
        visible: :all
      )
      expect(page.evaluate_script("arguments[0].open", pricing_details)).to be(true)
      expect(pricing_details["data-collapsible-open"]).to eq("true")
      expect(pricing_mode[:class].to_s.split).to include("input-field-error")
      expect(quantity[:class].to_s.split).not_to include("input-field-error")
      expect(row.all(".input-field-error", visible: :all).map { |field| field[:id] }).to eq([ pricing_mode[:id] ])
      expect(pricing_mode.find("option[value='explicit_line_total']", visible: :all)).to have_text(
        I18n.t("receipts.item_fields.pricing_modes.explicit_line_total")
      )
    end
    expect_mobile_viewport_without_horizontal_overflow

    set_viewport(width: 1280, height: 900, mobile: false)
    wait_for_pricing_layout(row)
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    set_viewport(width: 390, height: 844, mobile: true)

    save_receipt

    expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
    aggregate_failures "通常保存を明示確認として扱いsourceと金額を変えない" do
      expect(item.reload).to have_attributes(
        pricing_source_kind: "count_unit_price",
        price: 100,
        quantity: BigDecimal("1"),
        quantity_unit_code: "each",
        original_line_total: 100,
        line_total: 100,
        needs_review: false,
        review_reasons: []
      )
      expect(receipt.reload).to have_attributes(
        subtotal_amount: 100,
        tax_amount: 0,
        total_amount: 100,
        status: "review_needed",
        review_reasons: [ "ocr_unreadable" ]
      )
    end

    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    row = item_row_named("既存商品")
    panel = row.find("[data-receipt-form-target='itemDetailsPanel']", visible: :all)
    pricing_mode = row.find("[data-receipt-form-target='pricingSourceModeInput']", visible: :all)

    aggregate_failures "確認後は通常の閉じた表示へ戻す" do
      expect(panel["aria-hidden"]).to eq("true")
      expect(page.evaluate_script("arguments[0].inert", panel)).to be(true)
      expect(pricing_mode[:class].to_s.split).not_to include("input-field-error")
    end
    expect_mobile_viewport_without_horizontal_overflow
    expect_browser_console_clean
  end

  it "3モードと計算根拠を段階表示し、exact previewとsource不変の検証後に税込基準価格を保存する" do
    user = create_system_test_user
    receipt = create_editable_receipt(user: user, store_name: "基準価格UI確認店")

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    click_button I18n.t("receipts.form.buttons.add_item")

    row = all("[data-receipt-form-target='itemRow']", visible: :all).last
    row.find("input[name$='[confirmed_name]']").set("量り売り飲料")
    expand_item_row(row)
    details = pricing_source_details(row)
    aggregate_failures "通常時は計算方式の編集欄を二段目に閉じる" do
      expect(page.evaluate_script("arguments[0].open", details)).to be(false)
      expect(details["data-collapsible-open"]).to eq("false")
      content = details.find("[data-collapsible-details-target='content']", visible: :all)
      expect(content["aria-hidden"]).to eq("true")
      expect(page.evaluate_script("arguments[0].inert", content)).to be(true)
    end
    expand_pricing_source_details(row)
    row.find("[data-receipt-form-target='quantityInput']").set("1.5")
    select_option(row, target: "quantityUnitInput", value: "liter")

    mode_select = select_option(row, target: "pricingSourceModeInput", value: "reference_quantity_price")
    expect(mode_select.all("option", visible: :all).map(&:value)).to eq(
      %w[count_unit_price reference_quantity_price explicit_line_total]
    )
    expect(row.find("label[for='#{mode_select[:id]}']", visible: :all)).to have_text(
      I18n.t("receipts.item_fields.pricing_source_select")
    )

    reference_price = row.find("[data-receipt-form-target='referencePriceAmountInput']", visible: :all)
    reference_quantity = row.find("[data-receipt-form-target='referenceQuantityInput']", visible: :all)
    tax_rate = row.find("[data-receipt-form-target='taxRateInput']", visible: :all)
    reference_price.set("120.5")
    reference_quantity.set("500")
    tax_rate.set("10")
    select_option(row, target: "referenceQuantityUnitInput", value: "milliliter")

    reference_increment = row.find(
      "button[aria-label='#{I18n.t('shared.number_field.increment_aria', label: I18n.t('receipts.item_fields.reference_price_amount'))}']",
      visible: true
    )
    reference_decrement = row.find(
      "button[aria-label='#{I18n.t('shared.number_field.decrement_aria', label: I18n.t('receipts.item_fields.reference_price_amount'))}']",
      visible: true
    )
    reference_increment.click
    expect(reference_price.value).to eq("121.5")
    reference_decrement.click
    expect(reference_price.value).to eq("120.5")
    expect(page.evaluate_script("arguments[0].validity.valid", reference_price)).to be(true)
    reference_price.set("120")

    aggregate_failures "reference unit metadataは値を変えず入力精度だけを同期する" do
      expect(reference_line_total_display(row)).to have_text("¥360")
      expect(reference_quantity.value).to eq("500")
      expect(reference_quantity[:step]).to eq("0.001")
      expect(reference_quantity[:inputmode]).to eq("decimal")
      expect(row.find("[data-receipt-form-target='pricingSourceSummary']", visible: true)).to have_text(
        "120円 / 500ml（税込）"
      )
    end
    tax_inclusion = row.find("[data-receipt-form-target='referencePriceTaxInclusionInput']", visible: :all)
    expect(tax_inclusion.value).to eq("gross")
    expect(tax_inclusion[:type]).to eq("hidden")
    expect(tax_inclusion).not_to be_disabled

    select_option(row, target: "pricingSourceModeInput", value: "explicit_line_total")
    explicit_total = row.find("[data-receipt-form-target='explicitLineTotalInput']", visible: :all)
    explicit_total.set("450")
    row.find(
      "button[aria-label='#{I18n.t('shared.number_field.increment_aria', label: I18n.t('receipts.item_fields.explicit_line_total'))}']",
      visible: true
    ).click
    expect(explicit_total.value).to eq("451")
    row.find(
      "button[aria-label='#{I18n.t('shared.number_field.decrement_aria', label: I18n.t('receipts.item_fields.explicit_line_total'))}']",
      visible: true
    ).click
    expect(explicit_total.value).to eq("450")
    select_option(row, target: "pricingSourceModeInput", value: "reference_quantity_price")

    aggregate_failures "保存前の非選択mode draftはDOM内だけで復元する" do
      expect(reference_price.value).to eq("120")
      expect(reference_quantity.value).to eq("500")
      expect(row.find("[data-receipt-form-target='referenceQuantityUnitInput']", visible: :all).value).to eq("milliliter")
      expect(row.find("[data-receipt-form-target='explicitLineTotalInput']", visible: :all).value).to eq("450")
      expect(row.find("[data-receipt-form-target='explicitLineTotalInput']", visible: :all)).to be_disabled
    end

    collapse_item_row(row)
    summary = row.find("[data-receipt-form-target='pricingSourceSummary']", visible: true)
    aggregate_failures "折りたたみ中もauthorityを隠さない" do
      expect(summary).to have_text("120円 / 500ml（税込）")
      expect(summary.find(:xpath, "..", visible: :all)["aria-live"]).to eq("polite")
    end
    expect_mobile_viewport_without_horizontal_overflow

    expand_item_row(row)
    reference_price.set("999999999999")
    reference_quantity.set("9999.999")
    collapse_item_row(row)
    summary = row.find("[data-receipt-form-target='pricingSourceSummary']", visible: true)
    summary_container = summary.find(:xpath, "..", visible: :all)
    aggregate_failures "上限付近の長いauthorityも390pxで省略しない" do
      expect(summary).to have_text("999999999999円 / 9999.999ml（税込）")
      expect(summary[:class].to_s.split).to include("whitespace-normal", "break-words")
      expect(summary[:class].to_s.split).not_to include("truncate")
      expect(page.evaluate_script("arguments[0].scrollWidth <= arguments[0].clientWidth", summary_container)).to be(true)
    end
    expect_mobile_viewport_without_horizontal_overflow

    expand_item_row(row)
    reference_price.set("120")
    reference_quantity.set("500")

    select_option(row, target: "quantityUnitInput", value: "gram")
    aggregate_failures "非互換単位でsourceを書き換えない" do
      expect(row.find("[data-receipt-form-target='quantityInput']", visible: :all).value).to eq("1.5")
      expect(reference_price.value).to eq("120")
      expect(reference_quantity.value).to eq("500")
      expect(mode_select.value).to eq("reference_quantity_price")
      expect(reference_line_total_display(row)).to have_text(
        I18n.t("receipts.common.not_available")
      )
    end

    save_receipt

    error_summary = find("[data-receipt-form-target='invalidItemSourceSummary']", visible: true)
    expect(error_summary).to have_text(I18n.t("receipts.form.errors.invalid_item_pricing_source"))
    aggregate_failures "source rowを特定できない422は全visible明細を展開してsummaryへfocusする" do
      expect(page.evaluate_script("document.activeElement === arguments[0]", error_summary)).to be(true)
      expect(all("[data-receipt-form-target='itemRow']", visible: :all).reject do |candidate|
        candidate[:style].to_s.include?("display: none") ||
          candidate.find("[data-receipt-form-target='destroyField']", visible: :all, match: :first).value == "1"
      rescue Capybara::ElementNotFound
        false
      end).to all(satisfy do |candidate|
        candidate.find("[data-receipt-form-target='itemDetailsToggle']", visible: true, match: :first)["aria-expanded"] == "true"
      end)
      expect(all("details[data-receipt-pricing-source-details]", visible: :all)).to all(satisfy do |details|
        content = details.find("[data-collapsible-details-target='content']", visible: :all)
        page.evaluate_script("arguments[0].open", details) &&
          details["data-collapsible-open"] == "true" &&
          content["aria-hidden"] == "false" &&
          page.evaluate_script("arguments[0].inert", content) == false
      end)
    end
    expect_only_validation_failure_in_browser_console(receipt)
    expect(receipt.reload.receipt_items.count).to eq(1)

    row = expand_item_row(item_row_named("量り売り飲料"))
    mode_select = row.find("[data-receipt-form-target='pricingSourceModeInput']", visible: :all)
    reference_price = row.find("[data-receipt-form-target='referencePriceAmountInput']", visible: :all)
    reference_quantity = row.find("[data-receipt-form-target='referenceQuantityInput']", visible: :all)
    tax_rate = row.find("[data-receipt-form-target='taxRateInput']", visible: :all)
    aggregate_failures "422再表示でtyped sourceを保持する" do
      expect(mode_select.value).to eq("reference_quantity_price")
      expect(row.find("[data-receipt-form-target='quantityInput']", visible: :all).value).to eq("1.5")
      expect(row.find("[data-receipt-form-target='quantityUnitInput']", visible: :all).value).to eq("gram")
      expect(reference_price.value.to_d).to eq(BigDecimal("120"))
      expect(reference_quantity.value.to_d).to eq(BigDecimal("500"))
      expect(tax_rate.value).to eq("10")
      expect(row.find("[data-receipt-form-target='referenceQuantityUnitInput']", visible: :all).value).to eq("milliliter")
      expect(row.find("[data-receipt-form-target='referencePriceTaxInclusionInput']", visible: :all).value).to eq("gross")
    end

    select_option(row, target: "quantityUnitInput", value: "liter")
    expect(reference_line_total_display(row)).to have_text("¥360")
    save_receipt

    expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
    saved_item = receipt.reload.receipt_items.find_by!(confirmed_name: "量り売り飲料")
    expect(saved_item).to have_attributes(
      pricing_source_kind: "reference_quantity_price",
      quantity: BigDecimal("1.5"),
      quantity_unit_code: "liter",
      reference_price_amount: BigDecimal("120"),
      reference_quantity: BigDecimal("500"),
      reference_quantity_unit_code: "milliliter",
      reference_price_tax_inclusion: "gross",
      tax_rate: BigDecimal("0.1"),
      original_line_total: 360,
      line_total: 360
    )
    expect_mobile_viewport_without_horizontal_overflow
    expect_browser_console_clean
  end

  it "基準価格の3桁区切りと全角小数をserverと同じHALF_UP金額でpreviewする" do
    user = create_system_test_user
    receipt = create_editable_receipt(user: user, store_name: "基準価格数値入力確認店")

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    click_button I18n.t("receipts.form.buttons.add_item")

    row = all("[data-receipt-form-target='itemRow']", visible: :all).last
    row.find("input[name$='[confirmed_name]']").set("桁区切り基準価格商品")
    expand_item_row(row)
    expand_pricing_source_details(row)
    select_option(row, target: "pricingSourceModeInput", value: "reference_quantity_price")
    row.find("[data-receipt-form-target='quantityInput']", visible: true).set("１")
    reference_price = row.find("[data-receipt-form-target='referencePriceAmountInput']", visible: true)
    row.find("[data-receipt-form-target='referenceQuantityInput']", visible: true).set("１")
    row.find("[data-receipt-form-target='taxRateInput']", visible: true).set("０")

    reference_price.set("１，０００")
    expect(reference_line_total_display(row)).to have_text("¥1,000")

    reference_price.set("１，０００．５")
    expect(reference_line_total_display(row)).to have_text("¥1,001")

    save_receipt

    expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
    saved_item = receipt.reload.receipt_items.find_by!(confirmed_name: "桁区切り基準価格商品")
    aggregate_failures do
      expect(receipt).to have_attributes(subtotal_amount: 1_101, tax_amount: 0, total_amount: 1_101)
      expect(saved_item).to have_attributes(
        reference_price_amount: BigDecimal("1000.5"),
        original_line_total: 1_001,
        line_total: 1_001
      )
    end
    expect_mobile_viewport_without_horizontal_overflow
    expect_browser_console_clean
  end

  it "formulaから明示金額への切替で割引解除を取消でき、確定した場合だけintentを保存する" do
    user = create_system_test_user
    receipt = create_editable_receipt(user: user, store_name: "割引切替確認店")
    item = receipt.receipt_items.sole
    item.update!(
      price: 100,
      quantity: 2,
      original_line_total: 200,
      discount_rate: BigDecimal("0.10"),
      discount_amount: 20,
      line_total: 180
    )
    receipt.update!(subtotal_amount: 180, total_amount: 180)

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    row = expand_item_row(item_row_named("既存商品"))
    expand_pricing_source_details(row)
    mode_select = row.find("[data-receipt-form-target='pricingSourceModeInput']", visible: :all)
    discount_rate = row.find("[data-receipt-form-target='discountRateInput']", visible: :all)
    clear_intent = row.find(
      "[data-receipt-form-target='clearItemDiscountBeforeExplicitInput']",
      visible: :all
    )

    mode_select.find("option[value='explicit_line_total']", visible: :all).select_option
    dialog = find("dialog[data-confirm-dialog][open]", visible: true)
    expect(dialog).to have_text(I18n.t("receipts.item_fields.clear_discount_before_explicit_confirm"))
    dialog.find("[data-confirm-dialog-cancel][type='button']").click

    aggregate_failures "取消でformulaと割引を完全に維持する" do
      expect(mode_select.value).to eq("count_unit_price")
      expect(discount_rate.value.to_d).to eq(BigDecimal("10"))
      expect(clear_intent.value).to eq("0")
      expect(item.reload).to have_attributes(
        pricing_source_kind: "count_unit_price",
        discount_rate: BigDecimal("0.10"),
        discount_amount: 20
      )
    end

    mode_select.find("option[value='explicit_line_total']", visible: :all).select_option
    dialog = find("dialog[data-confirm-dialog][open]", visible: true)
    dialog.find("[data-confirm-dialog-confirm]").click

    aggregate_failures "明示確定でのみ割引解除intentを立てる" do
      expect(mode_select.value).to eq("explicit_line_total")
      expect(discount_rate.value).to eq("")
      expect(clear_intent.value).to eq("1")
    end
    explicit_total = row.find("[data-receipt-form-target='explicitLineTotalInput']", visible: :all)
    explicit_total.set("180")
    discount_rate.set("0")
    aggregate_failures "解除確認後の明示0%は新しいexplicit discount sourceとして扱う" do
      expect(clear_intent.value).to eq("1")
      expect(discount_rate.value).to eq("0")
      expect(explicit_total["aria-label"]).to eq(I18n.t("receipts.item_fields.explicit_line_total_before_discount"))
      expect(row.find("[data-receipt-form-target='explicitLineTotalHelp']", visible: true)).to have_text(
        I18n.t("receipts.item_fields.explicit_line_total_discount_help")
      )
    end
    save_receipt

    expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
    expect(item.reload).to have_attributes(
      pricing_source_kind: "explicit_line_total",
      price: nil,
      original_line_total: 180,
      line_total: 180,
      discount_rate: BigDecimal("0"),
      discount_amount: 0
    )
    expect_mobile_viewport_without_horizontal_overflow
    expect_browser_console_clean
  end

  it "金額欠損行はreference混在の再計算・通常保存・再表示でも明示0円と区別する" do
    user = create_system_test_user
    receipt = create_editable_receipt(user: user, store_name: "金額未設定確認店")
    missing_item = receipt.receipt_items.create!(
      confirmed_name: "金額未設定商品",
      quantity: 2,
      quantity_unit_code: "each",
      tax_rate: 0,
      needs_review: true,
      review_reasons: [ "item_pricing_mode_uncertain" ]
    )
    zero_item = receipt.receipt_items.create!(
      confirmed_name: "明示0円商品",
      quantity: 1,
      quantity_unit_code: "each",
      tax_rate: 0,
      pricing_source_kind: "explicit_line_total",
      original_line_total: 0,
      line_total: 0
    )
    reference_item = receipt.receipt_items.create!(
      confirmed_name: "基準価格商品",
      quantity: 250,
      quantity_unit_code: "gram",
      tax_rate: 0,
      pricing_source_kind: "reference_quantity_price",
      reference_price_amount: 120,
      reference_quantity: 100,
      reference_quantity_unit_code: "gram",
      reference_price_tax_inclusion: "gross",
      original_line_total: 300,
      line_total: 300
    )
    receipt.update!(status: "review_needed", subtotal_amount: 400, total_amount: 400)

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    missing_row = expand_item_row(item_row_named("金額未設定商品"))
    missing_row.find("[data-receipt-form-target='quantityInput']", visible: true).set("3")
    missing_row.find("[data-receipt-form-target='quantityInput']", visible: true).set("2")

    aggregate_failures do
      expect(missing_row.find("[data-receipt-form-target='pricingSourceSummary']", visible: true)).to have_text("金額未設定")
      expect(
        missing_row.all("[data-receipt-form-target='lineTotalDisplay']", visible: :all).map { |display| display.text(:all) }
      ).to all(eq(I18n.t("receipts.common.not_available")))
      expect(missing_row.find("[data-receipt-form-target='lineTotalInput']", visible: :all).value).to eq("")
      expect(item_row_named("明示0円商品")).to have_text("¥0")
      expect(item_row_named("基準価格商品")).to have_text("¥300")
    end

    save_receipt
    expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")

    aggregate_failures do
      expect(item_row_named("金額未設定商品").find("[data-receipt-form-target='pricingSourceSummary']", visible: true)).to have_text("金額未設定")
      expect(missing_item.reload).to have_attributes(
        price: nil,
        original_line_total: nil,
        line_total: nil,
        pricing_source_kind: nil,
        needs_review: true
      )
      expect(missing_item.review_reasons).to include("item_pricing_mode_uncertain")
      expect(zero_item.reload.line_total).to eq(0)
      expect(reference_item.reload.line_total).to eq(300)
      expect(receipt.reload.total_amount).to eq(400)
    end
    expect_mobile_viewport_without_horizontal_overflow
    expect_browser_console_clean
  end

  it "合計未設定では数量編集や再表示で0円を作らず支払額の同期を表示しない" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :review_needed,
      :with_image,
      user: user,
      subtotal_amount: nil,
      tax_amount: nil,
      total_amount: nil,
      review_reasons: [ "ocr_low_confidence" ]
    )
    item = receipt.receipt_items.create!(
      confirmed_name: "金額未設定商品",
      quantity: 2,
      quantity_unit_code: "each",
      tax_rate: 0,
      needs_review: true,
      review_reasons: [ "item_pricing_mode_uncertain" ]
    )
    payment = receipt.receipt_payments.create!(method: "現金", amount: 123)

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")

    aggregate_failures do
      expect(page).to have_css("[data-receipt-form-target='paymentAmountSum']", text: "¥123")
      expect(page).to have_css("[data-receipt-form-target='paymentReconciliationFinalAmount']", text: I18n.t("receipts.common.not_available"))
      expect(page).not_to have_css("[data-receipt-form-target='paymentMismatchWarning']", visible: true)
    end

    row = expand_item_row(item_row_named("金額未設定商品"))
    row.find("[data-receipt-form-target='quantityInput']", visible: true).set("3")
    row.find("[data-receipt-form-target='quantityInput']", visible: true).set("2")
    row.find("[data-receipt-form-target='priceInput']", visible: true).set("0")
    expect(page).to have_css("[data-receipt-form-target='totalAmount']", text: "¥0")
    row.find("[data-receipt-form-target='priceInput']", visible: true).set("")

    aggregate_failures do
      expect(page).to have_css("[data-receipt-form-target='totalAmount']", text: I18n.t("receipts.common.not_available"))
      expect(page).to have_css("[data-receipt-form-target='paymentDifferenceAmount']", text: I18n.t("receipts.common.not_available"))
      expect(page).not_to have_button(I18n.t("receipts.payment_fields.sync_to_final"), visible: true)
      expect(row.find("[data-receipt-form-target='lineTotalInput']", visible: :all).value).to eq("")
    end

    save_receipt
    expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")

    aggregate_failures do
      expect(item.reload).to have_attributes(price: nil, original_line_total: nil, line_total: nil, pricing_source_kind: nil)
      expect(receipt.reload.total_amount).to be_nil
      expect(payment.reload.amount).to eq(123)
      expect(page).not_to have_css("[data-receipt-form-target='paymentMismatchWarning']", visible: true)
    end
    expect_mobile_viewport_without_horizontal_overflow
    expect_browser_console_clean
  end

  it "割引前source未記録の明示金額は推測せず、保存済みderived表示と明示0円を区別する" do
    user = create_system_test_user
    receipt = create_editable_receipt(user: user, store_name: "明示金額source確認店")
    missing_source_item = receipt.receipt_items.sole
    missing_source_item.update_columns(
      price: nil,
      pricing_source_kind: "explicit_line_total",
      original_line_total: nil,
      line_total: 180,
      discount_rate: nil,
      discount_amount: 20
    )
    receipt.receipt_items.create!(
      confirmed_name: "明示0円商品",
      price: nil,
      quantity: 1,
      quantity_unit_code: "each",
      tax_rate: 0,
      pricing_source_kind: "explicit_line_total",
      original_line_total: 0,
      line_total: 0,
      discount_rate: BigDecimal("0"),
      discount_amount: 0,
      needs_review: false,
      review_reasons: []
    )
    receipt.update_columns(subtotal_amount: 180, tax_amount: 0, total_amount: 180)

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")

    missing_row = item_row_named("既存商品")
    zero_row = item_row_named("明示0円商品")
    missing_input = missing_row.find(
      "[data-receipt-form-target='explicitLineTotalInput']",
      visible: :all
    )
    zero_input = zero_row.find(
      "[data-receipt-form-target='explicitLineTotalInput']",
      visible: :all
    )
    missing_summary = missing_row.find(
      "[data-receipt-form-target='pricingSourceSummary']",
      visible: true
    )
    hidden_line_total = missing_row.find(
      "[data-receipt-form-target='lineTotalInput']",
      visible: :all
    )

    aggregate_failures do
      expect(missing_input.value).to eq("")
      expect(missing_input[:required]).to eq("true")
      expect(missing_input["aria-label"]).to eq(I18n.t("receipts.item_fields.explicit_line_total_before_discount"))
      expect(missing_summary).to have_text(I18n.t("receipts.item_fields.explicit_line_total_before_discount"))
      expect(missing_summary).not_to have_text("180円")
      expect(hidden_line_total.value).to eq("180")
      expect(
        missing_row.all("[data-receipt-form-target='lineTotalDisplay']", visible: :all).map { |display| display.text(:all) }
      ).to all(include("¥180"))
      expect(find("[data-receipt-form-target='totalAmount']", visible: :all)).to have_text(
        I18n.t("receipts.common.not_available")
      )

      expect(zero_input.value).to eq("0")
      expect(zero_row.find("[data-receipt-form-target='pricingSourceSummary']", visible: true)).to have_text(
        "割引前明細金額 0円"
      )
    end

    expand_item_row(missing_row)
    missing_row.find("[data-receipt-form-target='taxRateInput']", visible: :all).set("8")
    expect(
      missing_row.all("[data-receipt-form-target='lineTotalDisplay']", visible: :all).map { |display| display.text(:all) }
    ).to all(include("¥180"))

    missing_row.find("[data-receipt-form-target='discountRateInput']", visible: :all).set("")
    expand_item_row(zero_row)
    zero_row.find("[data-receipt-form-target='discountRateInput']", visible: :all).set("0")
    page.execute_script("arguments[0].required = false", missing_input)
    save_receipt

    expect(find("[data-receipt-form-target='invalidItemSourceSummary']", visible: true)).to have_text(
      I18n.t("receipts.form.errors.invalid_item_pricing_source")
    )
    missing_row = item_row_named("既存商品")
    zero_row = item_row_named("明示0円商品")
    missing_input = missing_row.find("[data-receipt-form-target='explicitLineTotalInput']", visible: :all)

    aggregate_failures "422再表示で保存済みabsolute discount sourceを維持する" do
      expect(missing_input.value).to eq("")
      expect(missing_input[:required]).to eq("true")
      expect(missing_input["aria-label"]).to eq(I18n.t("receipts.item_fields.explicit_line_total_before_discount"))
      expect(missing_row.find("[data-receipt-form-target='pricingSourceSummary']", visible: true)).to have_text(
        I18n.t("receipts.item_fields.explicit_line_total_before_discount")
      )
      expect(missing_row.find("[data-receipt-form-target='lineTotalInput']", visible: :all).value).to eq("180")
      expect(
        missing_row.all("[data-receipt-form-target='lineTotalDisplay']", visible: :all).map { |display| display.text(:all) }
      ).to all(include("¥180"))
      expect(find("[data-receipt-form-target='totalAmount']", visible: :all)).to have_text(
        I18n.t("receipts.common.not_available")
      )

      expect(zero_row.find("[data-receipt-form-target='discountRateInput']", visible: :all).value).to eq("0")
      expect(zero_row.find("[data-receipt-form-target='explicitLineTotalInput']", visible: :all).value).to eq("0")
      expect(zero_row.find("[data-receipt-form-target='pricingSourceSummary']", visible: true)).to have_text(
        "割引前明細金額 0円"
      )
    end
    expect(missing_source_item.reload).to have_attributes(
      original_line_total: nil,
      line_total: 180,
      discount_rate: nil,
      discount_amount: 20
    )
    expect_only_validation_failure_in_browser_console(receipt)
  end

  it "解析済み税込金額を税抜reference sourceへ戻さず初期表示・数量往復・保存で維持する" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "税抜計量確認店",
      purchased_at: Time.zone.local(2026, 8, 13, 13, 0, 0),
      payment_method: "cash",
      subtotal_amount: 600,
      tax_amount: 48,
      total_amount: 648,
      amount_calculation_profile: {
        "schema_version" => 1,
        "context" => "analysis",
        "profile" => {
          "tax_rounding_mode" => "floor",
          "discount_rounding_mode" => "round",
          "receipt_tax_basis" => "tax_added_to_subtotal",
          "item_amount_basis" => "line_total_as_net",
          "tax_detail_amount_basis" => "net"
        }
      },
      review_reasons: []
    )
    item = receipt.receipt_items.create!(
      confirmed_name: "計量確認品",
      price: nil,
      quantity: 250,
      quantity_unit_code: "gram",
      tax_rate: BigDecimal("0.08"),
      original_line_total: 600,
      line_total: 648,
      pricing_source_kind: "reference_quantity_price",
      reference_price_amount: BigDecimal("240"),
      reference_quantity: 100,
      reference_quantity_unit_code: "gram",
      reference_price_tax_inclusion: "net",
      needs_review: false,
      review_reasons: []
    )
    receipt.receipt_tax_details.create!(rate: BigDecimal("0.08"), net_amount: 600, amount: 48)

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    row = expand_item_row(item_row_named("計量確認品"))
    expect(reference_line_total_display(row)).to have_text("¥648")
    expect(page).to have_css("[data-receipt-form-target='totalAmount']", text: "¥648")
    expect(item.reload.line_total).to eq(648)

    quantity = row.find("[data-receipt-form-target='quantityInput']", visible: true)
    quantity.set("300")
    expect(reference_line_total_display(row)).to have_text("¥777")
    quantity.set("250")
    expect(reference_line_total_display(row)).to have_text("¥648")
    expect(page).to have_css("[data-receipt-form-target='totalAmount']", text: "¥648")

    save_receipt
    expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
    aggregate_failures do
      expect(receipt.reload).to have_attributes(subtotal_amount: 600, tax_amount: 48, total_amount: 648)
      expect(item.reload).to have_attributes(
        price: nil,
        quantity: BigDecimal("250"),
        pricing_source_kind: "reference_quantity_price",
        reference_price_amount: BigDecimal("240"),
        reference_quantity: BigDecimal("100"),
        reference_quantity_unit_code: "gram",
        reference_price_tax_inclusion: "net",
        original_line_total: 600,
        line_total: 600
      )
    end

    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    row = expand_item_row(item_row_named("計量確認品"))
    expect(reference_line_total_display(row)).to have_text("¥648")
    expect(page).to have_css("[data-receipt-form-target='totalAmount']", text: "¥648")
    expect_mobile_viewport_without_horizontal_overflow
    expect_browser_console_clean
  end

  it "referenceの絶対額割引は換算率が循環小数でも数量変更・保存で絶対額を維持する" do
    user = create_system_test_user
    receipt = create_editable_receipt(user: user, store_name: "絶対額割引確認店")
    item = receipt.receipt_items.sole
    item.update!(
      price: nil,
      quantity: 100,
      quantity_unit_code: "gram",
      original_line_total: 600,
      line_total: 550,
      discount_amount: 50,
      discount_rate: nil,
      pricing_source_kind: "reference_quantity_price",
      reference_price_amount: 600,
      reference_quantity: 100,
      reference_quantity_unit_code: "gram",
      reference_price_tax_inclusion: "gross"
    )
    receipt.update!(subtotal_amount: 550, total_amount: 550)

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    row = expand_item_row(item_row_named("既存商品"))
    expect(reference_line_total_display(row)).to have_text("¥550")
    expect(page).to have_css("[data-receipt-form-target='totalAmount']", text: "¥550")

    quantity = row.find("[data-receipt-form-target='quantityInput']", visible: true)
    quantity.set("200")
    expect(reference_line_total_display(row)).to have_text("¥1,150")
    quantity.set("100")
    expect(reference_line_total_display(row)).to have_text("¥550")
    save_receipt

    expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
    aggregate_failures do
      expect(receipt.reload).to have_attributes(subtotal_amount: 550, tax_amount: 0, total_amount: 550)
      expect(item.reload).to have_attributes(
        discount_amount: 50,
        discount_rate: nil,
        original_line_total: 600,
        line_total: 550
      )
    end
    expect_browser_console_clean
  end

  it "保存済み税抜reference sourceをTurbo backと再保存で維持する" do
    user = create_system_test_user
    external_net_profile = {
      "schema_version" => 1,
      "context" => "analysis",
      "profile" => {
        "tax_rounding_mode" => "floor",
        "discount_rounding_mode" => "round",
        "receipt_tax_basis" => "tax_added_to_subtotal",
        "item_amount_basis" => "line_total_as_net",
        "tax_detail_amount_basis" => "net"
      }
    }
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "税抜基準価格維持店",
      purchased_at: Time.zone.local(2026, 8, 13, 13, 0, 0),
      payment_method: "cash",
      subtotal_amount: 110,
      tax_amount: 11,
      total_amount: 121,
      amount_calculation_profile: external_net_profile,
      review_reasons: []
    )
    item = receipt.receipt_items.create!(
      confirmed_name: "税抜基準商品",
      price: nil,
      quantity: 1,
      quantity_unit_code: "liter",
      tax_rate: BigDecimal("0.10"),
      original_line_total: 110,
      line_total: 110,
      pricing_source_kind: "reference_quantity_price",
      reference_price_amount: BigDecimal("110"),
      reference_quantity: 1,
      reference_quantity_unit_code: "liter",
      reference_price_tax_inclusion: "net",
      needs_review: false,
      review_reasons: []
    )
    receipt.receipt_tax_details.create!(rate: BigDecimal("0.10"), net_amount: 110, amount: 11)

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    row = expand_item_row(item_row_named("税抜基準商品"))
    expand_pricing_source_details(row)
    reference_price = row.find("[data-receipt-form-target='referencePriceAmountInput']", visible: :all)
    tax_inclusion = row.find("[data-receipt-form-target='referencePriceTaxInclusionInput']", visible: :all)

    aggregate_failures "税抜sourceを明示し、切替UIは作らない" do
      expect(row.find("[data-receipt-form-target='pricingSourceModeInput']", visible: :all).value).to eq(
        "reference_quantity_price"
      )
      expect(reference_price.value).to eq("110")
      expect(tax_inclusion.value).to eq("net")
      expect(tax_inclusion[:type]).to eq("hidden")
      expect(tax_inclusion).not_to be_disabled
      expect(row).to have_text("税抜基準")
      expect(reference_line_total_display(row)).to have_text("¥121")
      expect(row.find("[data-receipt-form-target='pricingSourceSummary']", visible: true)).to have_text(
        "110円 / 1L（税抜）"
      )
    end

    reference_price.set("130")
    expect(reference_line_total_display(row)).to have_text("¥143")
    find("a[href='#{settings_path}']", visible: true, match: :first).click
    expect(page).to have_current_path(settings_path, ignore_query: true)

    page.go_back
    expect(page).to have_current_path(edit_receipt_path(receipt), ignore_query: true)
    wait_for_stimulus_controller("receipt-form")
    row = expand_item_row(item_row_named("税抜基準商品"))

    details = pricing_source_details(row)
    aggregate_failures "Turbo cacheから計算方式の開閉状態も復元する" do
      expect(page.evaluate_script("arguments[0].open", details)).to be(true)
      expect(details["data-collapsible-open"]).to eq("true")
      content = details.find("[data-collapsible-details-target='content']", visible: :all)
      expect(content["aria-hidden"]).to eq("false")
      expect(page.evaluate_script("arguments[0].inert", content)).to be(false)
    end

    aggregate_failures "Turbo cacheから復元してもtyped sourceと税区分がdriftしない" do
      expect(row.find("[data-receipt-form-target='referencePriceAmountInput']", visible: :all).value).to eq("130")
      expect(row.find("[data-receipt-form-target='referencePriceTaxInclusionInput']", visible: :all).value).to eq("net")
      expect(row.find("[data-receipt-form-target='pricingSourceModeInput']", visible: :all).value).to eq(
        "reference_quantity_price"
      )
      expect(reference_line_total_display(row)).to have_text("¥143")
    end

    save_receipt

    expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
    aggregate_failures do
      expect(item.reload).to have_attributes(
        pricing_source_kind: "reference_quantity_price",
        reference_price_amount: BigDecimal("130"),
        reference_price_tax_inclusion: "net",
        original_line_total: 130,
        line_total: 130
      )
      expect(receipt.reload).to have_attributes(subtotal_amount: 130, tax_amount: 13, total_amount: 143)
    end

    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    row = expand_item_row(item_row_named("税抜基準商品"))
    expand_pricing_source_details(row)
    expect(row.find("[data-receipt-form-target='referencePriceTaxInclusionInput']", visible: :all).value).to eq("net")
    expect(row).to have_text("税抜基準")
    expect_mobile_viewport_without_horizontal_overflow
    expect_browser_console_clean
  end

  it "手動作成の日次上限422で3行のreference authorityを重複なく保持する" do
    user = create_system_test_user
    create(:usage_counter, user: user, key: "manual_receipts_per_day", used_count: 50)

    sign_in_through_browser(user)
    visit new_receipt_path
    wait_for_stimulus_controller("receipt-form")
    find("input[name='receipt[store_name]']").set("日次上限browser保持店")
    find("select[name='receipt[payment_method]'] option[value='cash']").select_option

    sources = [
      {
        name: "基準価格商品A",
        quantity: "1.0",
        unit: "liter",
        price: "1000.0",
        reference_quantity: "1000.5",
        reference_unit: "milliliter"
      },
      {
        name: "基準価格商品B",
        quantity: "750.25",
        unit: "gram",
        price: "123.45",
        reference_quantity: "100.0",
        reference_unit: "gram"
      },
      {
        name: "基準価格商品C",
        quantity: "2.0",
        unit: "liter",
        price: "45.6",
        reference_quantity: "0.5",
        reference_unit: "liter"
      }
    ]
    actual_row_selector =
      "[data-receipt-form-target='itemsContainer'] > " \
      "[data-controller~='swipe-action'] [data-receipt-form-target='itemRow']"

    sources.each_with_index do |source, index|
      click_button I18n.t("receipts.form.buttons.add_item") if index.positive?
      row = all(actual_row_selector, visible: :all).last
      row.find("input[name$='[confirmed_name]']", visible: :all).set(source.fetch(:name))
      expand_item_row(row)
      expand_pricing_source_details(row)
      row.find("[data-receipt-form-target='quantityInput']", visible: :all).set(source.fetch(:quantity))
      select_option(row, target: "quantityUnitInput", value: source.fetch(:unit))
      select_option(row, target: "pricingSourceModeInput", value: "reference_quantity_price")
      row.find("[data-receipt-form-target='referencePriceAmountInput']", visible: :all).set(source.fetch(:price))
      row.find("[data-receipt-form-target='referenceQuantityInput']", visible: :all).set(
        source.fetch(:reference_quantity)
      )
      select_option(row, target: "referenceQuantityUnitInput", value: source.fetch(:reference_unit))
    end

    save_receipt

    expect(page).to have_css("form#new_receipt_form")
    expect(page).to have_text(I18n.t("flash.usage_limits.manual_receipts_exceeded"))
    rows = all(actual_row_selector, visible: :all)

    aggregate_failures "failure response" do
      expect(rows.size).to eq(3)
      expect(user.receipts.where(store_name: "日次上限browser保持店")).to be_empty
      expect(UsageCounter.find_by!(user: user, key: "manual_receipts_per_day").used_count).to eq(50)
    end

    sources.each do |source|
      row = item_row_named(source.fetch(:name))

      aggregate_failures source.fetch(:name) do
        expect(row.find("[data-receipt-form-target='pricingSourceModeInput']", visible: :all).value).to eq(
          "reference_quantity_price"
        )
        expect(row.find("[data-receipt-form-target='quantityInput']", visible: :all).value).to eq(
          source.fetch(:quantity)
        )
        expect(row.find("[data-receipt-form-target='quantityUnitInput']", visible: :all).value).to eq(
          source.fetch(:unit)
        )
        expect(row.find("[data-receipt-form-target='referencePriceAmountInput']", visible: :all).value).to eq(
          source.fetch(:price)
        )
        expect(row.find("[data-receipt-form-target='referenceQuantityInput']", visible: :all).value).to eq(
          source.fetch(:reference_quantity)
        )
        expect(row.find("[data-receipt-form-target='referenceQuantityUnitInput']", visible: :all).value).to eq(
          source.fetch(:reference_unit)
        )
        expect(row.find("[data-receipt-form-target='referencePriceTaxInclusionInput']", visible: :all).value).to eq(
          "gross"
        )
      end
    end

    severe_entries = page.driver.browser.logs.get(:browser).select do |entry|
      entry.level == "SEVERE" && !blocked_external_font_entry?(entry)
    end
    validation_entries, unexpected_entries = severe_entries.partition do |entry|
      entry.message.include?("/receipts") && entry.message.include?("422 (Unprocessable Content)")
    end
    aggregate_failures "browser console" do
      expect(validation_entries.size).to eq(1)
      expect(unexpected_entries).to be_empty
    end
  end
end
