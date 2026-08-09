require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "レシート編集の実Chrome入力回帰", type: :system, mobile: true do
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

  def receipt_item_row
    find("[data-receipt-form-target='itemRow']", match: :first)
  end

  def expanded_receipt_item_row
    item_row = receipt_item_row
    expand_receipt_item_row(item_row)
  end

  def expand_receipt_item_row(item_row)
    toggle = item_row.find("[data-receipt-form-target='itemDetailsToggle']", match: :first)
    panel = item_row.find("[data-receipt-form-target='itemDetailsPanel']", visible: :all)
    toggle.click unless toggle["aria-expanded"] == "true"
    expect(panel["aria-hidden"]).to eq("false")
    expect(page.evaluate_script("arguments[0].inert", panel)).to be(false)
    item_row
  end

  def select_with_keyboard(select_element, value)
    options = select_element.all("option", visible: :all)
    option_index = options.index { |option| option.value == value }
    raise "Select option not found: #{value}" unless option_index

    select_element.send_keys(options[option_index].text(:all))
    expect(select_element.value).to eq(value)
  end

  def expect_category_label_association(row)
    select_element = row.find("select[name$='[category]']", visible: :all)
    select_id = select_element[:id]
    expect(select_id).to be_present
    label = row.find("label[for='#{select_id}']", visible: :all)

    aggregate_failures do
      expect(label.text(:all)).to eq(I18n.t("receipts.item_fields.category"))
      expect(label[:for]).to eq(select_id)
    end

    select_element
  end

  def expect_mobile_viewport_without_horizontal_overflow
    expect_viewport_without_horizontal_overflow(390)
  end

  def expect_viewport_without_horizontal_overflow(width)
    expect(page.evaluate_script("window.innerWidth")).to eq(width)
    expect(
      page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
    ).to be(true)
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

  def quantity_unit_layout_metrics(row)
    quantity_input = row.find("[data-receipt-form-target='quantityInput']", visible: :all)
    unit_select = row.find("[data-receipt-form-target='quantityUnitInput']", visible: :all)
    price_input = row.find("[data-receipt-form-target='priceInput']", visible: :all)

    maximum_price_text = SystemSettings::AMOUNT_LIMIT_CONFIGURABLE_MAX.to_s

    page.evaluate_script(<<~JAVASCRIPT, quantity_input, unit_select, price_input, maximum_price_text)
      (() => {
        const quantityInput = arguments[0]
        const unitSelect = arguments[1]
        const priceInput = arguments[2]
        const maximumPriceText = arguments[3]
        const quantityWrapper = quantityInput.closest(".field-control-wrapper")
        const priceWrapper = priceInput.closest(".field-control-wrapper")
        const quantityField = quantityInput.closest(".receipt-form-item-mobile-detail-field")
        const priceField = priceInput.closest(".receipt-form-item-mobile-detail-field")
        const quantityWrapperRect = quantityWrapper.getBoundingClientRect()
        const quantityInputRect = quantityInput.getBoundingClientRect()
        const unitSelectRect = unitSelect.getBoundingClientRect()
        const priceInputRect = priceInput.getBoundingClientRect()
        const quantityFieldRect = quantityField.getBoundingClientRect()
        const priceFieldRect = priceField.getBoundingClientRect()
        const priceButtons = Array.from(priceWrapper.querySelectorAll("button"))
        const priceButtonRects = priceButtons
          .map((button) => button.getBoundingClientRect())
          .filter((rect) => rect.width > 0 && rect.height > 0)
        const quantityStyle = window.getComputedStyle(quantityInput)
        const priceStyle = window.getComputedStyle(priceInput)
        const visibleWidthWithin = (element, wrapper) => {
          const elementRect = element.getBoundingClientRect()
          const wrapperRect = wrapper.getBoundingClientRect()
          return Math.max(
            0,
            Math.min(elementRect.right, wrapperRect.right) - Math.max(elementRect.left, wrapperRect.left)
          )
        }
        const selectStyle = window.getComputedStyle(unitSelect)
        const canvas = document.createElement("canvas")
        const context = canvas.getContext("2d")
        context.font = selectStyle.font
        const longestOptionWidth = Math.max(
          ...Array.from(unitSelect.options, (option) => context.measureText(option.text).width)
        )
        const horizontalPadding =
          Number.parseFloat(selectStyle.paddingLeft) + Number.parseFloat(selectStyle.paddingRight)
        context.font = quantityStyle.font
        const requiredQuantityContentWidth = context.measureText(quantityInput.max).width
        context.font = priceStyle.font
        const requiredPriceContentWidth = context.measureText(maximumPriceText).width
        const contentWidthWithin = (element, wrapper, style) =>
          visibleWidthWithin(element, wrapper) -
          Number.parseFloat(style.paddingLeft) -
          Number.parseFloat(style.paddingRight)

        return {
          viewportWidth: window.innerWidth,
          visibleQuantityContentWidth: contentWidthWithin(quantityInput, quantityWrapper, quantityStyle),
          requiredQuantityContentWidth,
          quantityWrapperWidth: quantityWrapperRect.width,
          unitSelectWidth: unitSelectRect.width,
          requiredUnitSelectWidth: longestOptionWidth + horizontalPadding,
          unitSelectWithinWrapper:
            unitSelectRect.left >= quantityWrapperRect.left - 1 &&
            unitSelectRect.right <= quantityWrapperRect.right + 1,
          unitTextAlign: selectStyle.textAlign,
          unitTextAlignLast: selectStyle.textAlignLast,
          unitOnSameLine: Math.abs(unitSelectRect.top - quantityInputRect.top) < 1,
          unitBelowQuantity: unitSelectRect.top >= quantityInputRect.bottom - 1,
          visiblePriceContentWidth: contentWidthWithin(priceInput, priceWrapper, priceStyle),
          requiredPriceContentWidth,
          visiblePriceButtonCount: priceButtonRects.length,
          visiblePriceButtonWidths: priceButtonRects.map((rect) => rect.width),
          quantityBeforePriceWithoutOverlap: quantityFieldRect.bottom <= priceFieldRect.top + 1,
          priceControlsDoNotOverlap:
            priceButtonRects.length !== 2 ||
            (priceButtonRects[0].right <= priceInputRect.left + 1 &&
              priceInputRect.right <= priceButtonRects[1].left + 1),
          horizontalOverflow: document.documentElement.scrollWidth > window.innerWidth
        }
      })()
    JAVASCRIPT
  end

  def receipt_adjustment_target_id(adjustment)
    "receipt-adjustment-#{adjustment.id}"
  end

  def receipt_adjustment_row(adjustment)
    find("##{receipt_adjustment_target_id(adjustment)}")
  end

  def expect_adjustment_row_expanded(row, target_id)
    panel_id = "#{target_id}-details"

    aggregate_failures do
      expect(row).to have_css(
        "[data-receipt-form-target='adjustmentDetailsPanel']##{panel_id}.is-open[aria-hidden='false']:not([inert])",
        visible: :all
      )
      expect(row).to have_css(
        "[data-receipt-form-target='adjustmentDetailsToggle'][aria-controls='#{panel_id}'][aria-expanded='true']",
        count: 2,
        visible: :all
      )
    end
  end

  def expect_adjustment_row_collapsed(row, target_id)
    panel_id = "#{target_id}-details"

    aggregate_failures do
      expect(row).to have_css(
        "[data-receipt-form-target='adjustmentDetailsPanel']##{panel_id}[aria-hidden='true'][inert]:not(.is-open)",
        visible: :all
      )
      expect(row).to have_css(
        "[data-receipt-form-target='adjustmentDetailsToggle'][aria-controls='#{panel_id}'][aria-expanded='false']",
        count: 2,
        visible: :all
      )
    end
  end

  def visible_adjustment_toggle(row)
    row.find("[data-receipt-form-target='adjustmentDetailsToggle']", visible: true)
  end

  def element_has_focus?(element)
    page.evaluate_script("document.activeElement === arguments[0]", element)
  end

  def expect_visible_adjustment_toggle_focused(row)
    expect(row).to have_css(
      "[data-receipt-form-target='adjustmentDetailsToggle']:focus",
      visible: true
    )
  end

  def wait_for_visual_motion_to_finish(element)
    settled = page.evaluate_async_script(<<~JAVASCRIPT, element, Capybara.default_max_wait_time * 1000)
      const target = arguments[0]
      const timeoutMilliseconds = arguments[1]
      const done = arguments[arguments.length - 1]
      let completed = false

      const finish = (result) => {
        if (completed) return

        completed = true
        done(result)
      }

      window.setTimeout(() => finish(false), timeoutMilliseconds)
      window.requestAnimationFrame(() => {
        window.requestAnimationFrame(() => {
          const animations = target.getAnimations({ subtree: true })
          const fontsReady = document.fonts?.ready || Promise.resolve()
          Promise.all([
            fontsReady,
            ...animations.map((animation) => animation.finished.catch(() => undefined))
          ])
            .then(() => finish(true))
        })
      })
    JAVASCRIPT

    expect(settled).to be(true), "CSS motion did not finish"
  end

  def click_mobile_save_button
    focus_released = page.evaluate_async_script(<<~JAVASCRIPT)
      const done = arguments[arguments.length - 1]
      document.activeElement?.blur()

      window.setTimeout(() => done(true), 200)
    JAVASCRIPT
    expect(focus_released).to be(true)
    expect(page).to have_css(
      "[data-controller~='mobile-amount-summary']" \
      "[data-mobile-amount-summary-keyboard-visible='false'] " \
      ".receipt-amount-summary-save",
      visible: true
    )

    within("[data-controller~='mobile-amount-summary']") do
      click_button I18n.t("receipts.form.buttons.save")
    end
  end

  def mobile_amount_summary_metrics(maximum_amount_text: nil)
    page.evaluate_script(<<~JAVASCRIPT, maximum_amount_text, I18n.t("receipts.form.buttons.save"))
      (() => {
        const maximumAmountText = arguments[0]
        const saveLabel = arguments[1]
        const summary = document.querySelector("[data-controller~='mobile-amount-summary']")
        const amount = summary.querySelector("[data-receipt-form-target='totalAmount']")
        const details = summary.querySelector("[data-mobile-amount-summary-target='details']")
        const toggle = summary.querySelector("[data-mobile-amount-summary-target='toggle']")
        const toolbar = summary.querySelector(".receipt-amount-summary-toolbar")
        const heading = summary.querySelector(".receipt-amount-summary-heading")
        const title = summary.querySelector(".receipt-amount-summary-title")
        const decoration = summary.querySelector(".receipt-amount-summary-decoration")
        const decorationIcon = summary.querySelector(".receipt-amount-summary-decoration-icon")
        const detailList = summary.querySelector(".receipt-amount-summary-detail-list")
        const divider = summary.querySelector(".receipt-amount-summary-divider")
        const primaryDetails = Array.from(summary.querySelectorAll(".receipt-amount-summary-primary-detail"))
        const paymentAdjustmentRow = summary.querySelector("[data-receipt-form-target='paymentAdjustmentRow']")
        const finalPaymentRow = summary.querySelector("[data-receipt-form-target='finalPaymentRow']")
        const nav = document.querySelector("[data-mobile-ui-target='nav']")
        const memo = document.querySelector(".receipt-form-memo-card")
        const imagePreview = document.querySelector("#receipt-section-image-preview")
        const formContent = document.querySelector(".receipt-form-content")
        if (maximumAmountText) {
          amount.textContent = maximumAmountText
          amount.title = maximumAmountText
        }

        const visible = (element) => {
          if (!element) return false
          const style = window.getComputedStyle(element)
          const rect = element.getBoundingClientRect()
          return style.display !== "none" && style.visibility !== "hidden" && rect.width > 0 && rect.height > 0
        }
        const summaryRect = summary.getBoundingClientRect()
        const navRect = nav.getBoundingClientRect()
        const amountRect = amount.getBoundingClientRect()
        const toggleRect = toggle.getBoundingClientRect()
        const headingRect = heading.getBoundingClientRect()
        const titleRect = title.getBoundingClientRect()
        const decorationRect = decoration.getBoundingClientRect()
        const decorationIconRect = decorationIcon.getBoundingClientRect()
        const toolbarRect = toolbar.getBoundingClientRect()
        const detailsRect = details.getBoundingClientRect()
        const detailListRect = detailList.getBoundingClientRect()
        const dividerRect = divider.getBoundingClientRect()
        const primaryDetailRects = primaryDetails.map((detail) => detail.getBoundingClientRect())
        const memoRect = memo.getBoundingClientRect()
        const imagePreviewRect = imagePreview.getBoundingClientRect()
        const visibleSaveButtons = Array.from(document.querySelectorAll("button[type='submit']"))
          .filter((button) => button.textContent.trim() === saveLabel && visible(button))
        const visibleSaveButtonRect = visibleSaveButtons[0]?.getBoundingClientRect()
        const visibleToggle = visible(toggle)
        const firstControlLeft = visibleToggle ? toggleRect.left : visibleSaveButtonRect?.left
        const decorationIntersectionWidth = Math.max(
          0,
          Math.min(decorationRect.right, summaryRect.right) - Math.max(decorationRect.left, summaryRect.left)
        )
        const decorationIntersectionHeight = Math.max(
          0,
          Math.min(decorationRect.bottom, summaryRect.bottom) - Math.max(decorationRect.top, summaryRect.top)
        )
        const decorationIconIntersectionWidth = Math.max(
          0,
          Math.min(decorationIconRect.right, summaryRect.right) - Math.max(decorationIconRect.left, summaryRect.left)
        )
        const decorationIconIntersectionHeight = Math.max(
          0,
          Math.min(decorationIconRect.bottom, summaryRect.bottom) - Math.max(decorationIconRect.top, summaryRect.top)
        )
        const toggleStyle = window.getComputedStyle(toggle)
        const amountStyle = window.getComputedStyle(amount)
        const decorationIconStyle = window.getComputedStyle(decorationIcon)
        const summaryStyle = window.getComputedStyle(summary)
        const formContentStyle = window.getComputedStyle(formContent)
        const compactHeight = toolbarRect.height +
          Number.parseFloat(summaryStyle.paddingTop) + Number.parseFloat(summaryStyle.paddingBottom) +
          Number.parseFloat(summaryStyle.borderTopWidth) + Number.parseFloat(summaryStyle.borderBottomWidth)

        return {
          viewportWidth: window.innerWidth,
          viewportHeight: window.innerHeight,
          summaryPosition: window.getComputedStyle(summary).position,
          summaryTop: summaryRect.top,
          summaryBottom: summaryRect.bottom,
          summaryHeight: summaryRect.height,
          compactHeight,
          toolbarHeight: toolbarRect.height,
          amountText: amount.textContent.trim(),
          amountTitle: amount.title,
          amountTextOverflow: amountStyle.textOverflow,
          amountClientWidth: amount.clientWidth,
          amountScrollWidth: amount.scrollWidth,
          amountClipped: amount.scrollWidth > amount.clientWidth + 1,
          amountBeforeControls: amountRect.right <= firstControlLeft + 1,
          amountLeftInset: amountRect.left - summaryRect.left,
          headingRightInset: summaryRect.right - headingRect.right,
          titleText: title.textContent.trim(),
          titleVisible: visible(title),
          titleAboveAmount: titleRect.bottom <= amountRect.top + 1,
          decorationVisible: visible(decoration),
          decorationParentIsSummary: decoration.parentElement === summary,
          decorationTop: decorationRect.top,
          decorationTopOffset: decorationRect.top - summaryRect.top,
          decorationRightOffset: decorationRect.right - summaryRect.right,
          decorationWidthBeforeSave: visibleSaveButtonRect
            ? Math.max(0, Math.min(decorationRect.right, visibleSaveButtonRect.left) -
              Math.max(decorationRect.left, summaryRect.left))
            : decorationIntersectionWidth,
          decorationIntersectionWidth,
          decorationIntersectionHeight,
          decorationIconWidth: decorationIconRect.width,
          decorationIconHeight: decorationIconRect.height,
          decorationIconFontSize: Number.parseFloat(decorationIconStyle.fontSize),
          decorationIconIntersectionWidth,
          decorationIconIntersectionHeight,
          toggleVisible: visibleToggle,
          toggleWidth: toggleRect.width,
          toggleHeight: toggleRect.height,
          toggleBackground: toggleStyle.backgroundColor,
          toggleBorderWidth: toggleStyle.borderWidth,
          toggleBoxShadow: toggleStyle.boxShadow,
          visibleSaveButtonCount: visibleSaveButtons.length,
          visibleSaveButtonWidth: visibleSaveButtonRect?.width || 0,
          summaryInsideViewport: summaryRect.left >= -1 && summaryRect.right <= window.innerWidth + 1,
          controlsInsideSummary: Boolean(visibleSaveButtonRect) &&
            (!visibleToggle || toggleRect.left >= summaryRect.left - 1) &&
            visibleSaveButtonRect.right <= summaryRect.right + 1,
          controlsInsideViewport: Boolean(visibleSaveButtonRect) &&
            (!visibleToggle || toggleRect.left >= -1) &&
            visibleSaveButtonRect.right <= window.innerWidth + 1,
          saveRightInset: Boolean(visibleSaveButtonRect) ? summaryRect.right - visibleSaveButtonRect.right : null,
          navVisible: visible(nav),
          summaryAboveNav: summaryRect.bottom <= navRect.top + 1,
          summaryAtViewportBottom: Math.abs(summaryRect.bottom - (window.innerHeight - 16)) <= 2,
          detailsHidden: details.getAttribute("aria-hidden"),
          detailsInert: details.inert,
          detailsHeight: detailsRect.height,
          toggleExpanded: toggle.getAttribute("aria-expanded"),
          primaryDetailsHorizontal: primaryDetailRects.length === 3 &&
            primaryDetailRects.every((rect) => rect.width > 0) &&
            primaryDetailRects.every((rect) => Math.abs(rect.top - primaryDetailRects[0].top) <= 2),
          paymentAdjustmentVisible: visible(paymentAdjustmentRow),
          finalPaymentVisible: visible(finalPaymentRow),
          dividerBelowDetails: detailListRect.bottom <= dividerRect.top + 1,
          dividerBeforeToolbar: dividerRect.bottom <= toolbarRect.top + 1,
          phoneDividerTopGap: dividerRect.top - detailListRect.bottom,
          phoneDividerBottomGap: toolbarRect.top - dividerRect.bottom,
          tabletDividerTopGap: dividerRect.top - toolbarRect.bottom,
          tabletDividerBottomGap: detailListRect.top - dividerRect.bottom,
          memoImageGap: imagePreviewRect.top - memoRect.bottom,
          imagePreviewBottom: imagePreviewRect.bottom,
          imagePreviewClearance: summaryRect.top - imagePreviewRect.bottom,
          formContentPaddingBottom: Number.parseFloat(formContentStyle.paddingBottom),
          measuredSummaryHeight: Number.parseFloat(
            formContent.style.getPropertyValue("--receipt-mobile-amount-summary-height")
          ),
          horizontalOverflow: document.documentElement.scrollWidth > window.innerWidth
        }
      })()
    JAVASCRIPT
  end

  def expect_only_validation_failure_in_browser_console(receipt)
    severe_entries = page.driver.browser.logs.get(:browser).select do |entry|
      entry.level == "SEVERE" && !blocked_external_font_entry?(entry)
    end
    validation_entries, unexpected_entries = severe_entries.partition do |entry|
      entry.message.include?(receipt_path(receipt)) &&
        entry.message.include?("422 (Unprocessable Content)")
    end

    expect(validation_entries.size).to eq(1)
    expect(unexpected_entries).to be_empty
  end

  it "不正な単価を保持し、修正後に明細を保存できる" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "モバイル編集店",
      purchased_at: Time.zone.local(2026, 7, 12, 12, 0, 0),
      payment_method: "cash",
      subtotal_amount: 91,
      tax_amount: 9,
      total_amount: 100
    )
    item = receipt.receipt_items.create!(
      raw_text: "OCR元商品名",
      confirmed_name: "編集前商品",
      price: 100,
      quantity: 1,
      quantity_unit_code: "each",
      tax_rate: BigDecimal("0.1"),
      line_total: 100,
      needs_review: false,
      review_reasons: []
    )
    queue_adapter = ActiveJob::Base.queue_adapter
    expect(queue_adapter).to respond_to(:enqueued_jobs)
    queued_job_count = queue_adapter.enqueued_jobs.size

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    expect_mobile_viewport_without_horizontal_overflow

    item_row = expanded_receipt_item_row
    item_row.find("input[name$='[confirmed_name]']").set("入力保持商品")
    item_row.find("input[name$='[price]']").set("1e2")
    click_mobile_save_button

    expect(page).to have_content(I18n.t("receipts.form.errors.invalid_numeric_input"))
    expect_only_validation_failure_in_browser_console(receipt)
    item_row = expanded_receipt_item_row
    expect(item_row.find("input[name$='[confirmed_name]']").value).to eq("入力保持商品")
    expect(item_row.find("input[name$='[price]']").value).to eq("1e2")
    expect(item.reload).to have_attributes(
      confirmed_name: "編集前商品",
      raw_text: "OCR元商品名",
      price: 100,
      line_total: 100
    )
    expect(receipt.reload.total_amount).to eq(100)
    expect(queue_adapter.enqueued_jobs.size).to eq(queued_job_count)
    expect_mobile_viewport_without_horizontal_overflow

    item_row.find("input[name$='[confirmed_name]']").set("保存後商品")
    item_row.find("input[name$='[price]']").set("200")
    click_mobile_save_button

    expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
    expect(page).to have_content("保存後商品")
    expect(item.reload).to have_attributes(
      confirmed_name: "保存後商品",
      raw_text: "OCR元商品名",
      price: 200,
      line_total: 200
    )
    expect(receipt.reload).to have_attributes(
      subtotal_amount: 182,
      tax_amount: 18,
      total_amount: 200,
      status: "completed"
    )
    expect_mobile_viewport_without_horizontal_overflow
    new_jobs = queue_adapter.enqueued_jobs.drop(queued_job_count)
    expect(new_jobs.map { |job| job[:job] }).to eq([ Turbo::Streams::ActionBroadcastJob ])
    expect_browser_console_clean
  end

  it "review reasonリンクから該当明細を展開して入力できる" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "レビュー対象店",
      purchased_at: Time.zone.local(2026, 7, 12, 12, 0, 0),
      payment_method: "cash",
      subtotal_amount: 91,
      tax_amount: 9,
      total_amount: 100
    )
    review_item = receipt.receipt_items.create!(
      raw_text: "OCR要確認商品",
      confirmed_name: "要確認商品",
      price: 100,
      quantity: 1,
      quantity_unit_code: "each",
      tax_rate: BigDecimal("0.1"),
      line_total: 100,
      needs_review: true,
      review_reasons: [ "item_tax_rate_uncertain" ]
    )
    receipt.update!(status: "review_needed", review_reasons: [])

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")

    target_id = "#{ReceiptsHelper::RECEIPT_REVIEW_TARGET_ITEM_ID_PREFIX}#{review_item.id}"
    item_row = find("##{target_id}")
    panel_selector = "[data-receipt-form-target='itemDetailsPanel']"
    toggle_selector = "[data-receipt-form-target='itemDetailsToggle']"

    aggregate_failures do
      expect(page.evaluate_script("window.location.hash")).to eq("")
      expect(item_row.find(panel_selector, visible: :all)["aria-hidden"]).to eq("true")
      expect(item_row).to have_css(
        "#{toggle_selector}[aria-expanded='false']",
        count: 2,
        visible: :all
      )
    end

    expect(page).to have_css("[data-receipt-review-notes-card][data-collapsible-enhanced='true']")
    review_card = find("[data-receipt-review-notes-card]")
    review_card.find("[data-receipt-notes-summary]").click

    target_link_selector = "a[data-review-reason-target-item='#{target_id}']"
    expect(review_card).to have_css(target_link_selector)
    review_card.find(target_link_selector).click

    expect(item_row).to have_css(
      "#{panel_selector}.is-open[aria-hidden='false']:not([inert])",
      visible: :all
    )
    expect(item_row).to have_css(
      "#{toggle_selector}[aria-expanded='true']",
      count: 2,
      visible: :all
    )
    expect(page.evaluate_script("window.location.hash")).to eq("##{target_id}")
    expect(element_has_focus?(item_row.find(toggle_selector, visible: true))).to be(false)

    tax_rate_input = item_row.find("[data-receipt-form-target='taxRateInput']")
    tax_rate_input.set("8")
    expect(tax_rate_input.value).to eq("8")

    expect_mobile_viewport_without_horizontal_overflow
    expect_browser_console_clean
  end

  it "review reasonリンクから対象調整行だけを展開し、既存の展開状態とARIAを維持する" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "調整レビュー対象店",
      purchased_at: Time.zone.local(2026, 7, 12, 12, 0, 0),
      payment_method: "cash",
      subtotal_amount: 100,
      tax_amount: 10,
      total_amount: 110
    )
    receipt.receipt_items.create!(
      raw_text: "展開維持商品",
      confirmed_name: "展開維持商品",
      price: 110,
      quantity: 1,
      quantity_unit_code: "each",
      tax_rate: BigDecimal("0.1"),
      line_total: 110,
      needs_review: false,
      review_reasons: []
    )
    first_review_adjustment = create(
      :receipt_adjustment,
      receipt: receipt,
      label: "要確認調整A",
      needs_review: true,
      review_reasons: [ "adjustment_uncertain" ],
      position_index: 1
    )
    second_review_adjustment = create(
      :receipt_adjustment,
      receipt: receipt,
      label: "要確認調整B",
      needs_review: true,
      review_reasons: [ "adjustment_uncertain" ],
      position_index: 2
    )
    already_open_adjustment = create(
      :receipt_adjustment,
      receipt: receipt,
      label: "手動展開済み調整",
      position_index: 3
    )
    untouched_adjustment = create(
      :receipt_adjustment,
      receipt: receipt,
      label: "未展開調整",
      position_index: 4
    )
    receipt.update!(status: "review_needed", review_reasons: [])

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")

    expanded_item_row = expanded_receipt_item_row
    already_open_row = receipt_adjustment_row(already_open_adjustment)
    visible_adjustment_toggle(already_open_row).click
    already_open_target_id = receipt_adjustment_target_id(already_open_adjustment)
    expect_adjustment_row_expanded(already_open_row, already_open_target_id)

    review_card = find("[data-receipt-review-notes-card]")
    review_card.find("[data-receipt-notes-summary]").click

    first_target_id = receipt_adjustment_target_id(first_review_adjustment)
    first_target_link = review_card.find(
      "a[data-review-reason-target-adjustment='#{first_target_id}']"
    )
    first_target_link.click

    first_row = receipt_adjustment_row(first_review_adjustment)
    second_row = receipt_adjustment_row(second_review_adjustment)
    untouched_row = receipt_adjustment_row(untouched_adjustment)
    expect_adjustment_row_expanded(first_row, first_target_id)
    expect_adjustment_row_expanded(already_open_row, already_open_target_id)
    expect(expanded_item_row).to have_css(
      "[data-receipt-form-target='itemDetailsPanel'].is-open[aria-hidden='false']:not([inert])",
      visible: :all
    )
    expect_adjustment_row_collapsed(
      second_row,
      receipt_adjustment_target_id(second_review_adjustment)
    )
    expect_adjustment_row_collapsed(
      untouched_row,
      receipt_adjustment_target_id(untouched_adjustment)
    )
    expect(page.evaluate_script("window.location.hash")).to eq("##{first_target_id}")
    expect_visible_adjustment_toggle_focused(first_row)

    second_target_id = receipt_adjustment_target_id(second_review_adjustment)
    review_card.find(
      "a[data-review-reason-target-adjustment='#{second_target_id}']"
    ).send_keys(:enter)

    expect_adjustment_row_expanded(second_row, second_target_id)
    expect_adjustment_row_expanded(first_row, first_target_id)
    expect_adjustment_row_expanded(already_open_row, already_open_target_id)
    expect_adjustment_row_collapsed(
      untouched_row,
      receipt_adjustment_target_id(untouched_adjustment)
    )
    expect(page.evaluate_script("window.location.hash")).to eq("##{second_target_id}")
    expect_visible_adjustment_toggle_focused(second_row)

    page.execute_script("document.activeElement?.blur()")
    page.go_back
    expect(page.evaluate_script("window.location.hash")).to eq("##{first_target_id}")
    expect_adjustment_row_expanded(first_row, first_target_id)
    expect_adjustment_row_expanded(second_row, second_target_id)
    expect(element_has_focus?(visible_adjustment_toggle(first_row))).to be(false)

    page.go_forward
    expect(page.evaluate_script("window.location.hash")).to eq("##{second_target_id}")
    expect_adjustment_row_expanded(first_row, first_target_id)
    expect_adjustment_row_expanded(second_row, second_target_id)
    expect(element_has_focus?(visible_adjustment_toggle(second_row))).to be(false)
    expect_mobile_viewport_without_horizontal_overflow
    expect_browser_console_clean
  end

  it "direct hashでは調整行を展開してもfocusを移動しない" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "直接リンク確認店",
      purchased_at: Time.zone.local(2026, 7, 12, 12, 0, 0),
      payment_method: "cash",
      subtotal_amount: 100,
      tax_amount: 10,
      total_amount: 110
    )
    adjustment = create(
      :receipt_adjustment,
      receipt: receipt,
      label: "直接リンク対象調整",
      needs_review: true,
      review_reasons: [ "adjustment_uncertain" ]
    )
    receipt.update!(status: "review_needed", review_reasons: [])

    sign_in_through_browser(user)
    set_viewport(width: 1440, height: 1000, mobile: false)
    target_id = receipt_adjustment_target_id(adjustment)
    visit "#{edit_receipt_path(receipt)}##{target_id}"
    wait_for_stimulus_controller("receipt-form")

    row = receipt_adjustment_row(adjustment)
    toggle = visible_adjustment_toggle(row)
    expect_adjustment_row_expanded(row, target_id)
    expect(page.evaluate_script("window.location.hash")).to eq("##{target_id}")
    expect(element_has_focus?(toggle)).to be(false)
    expect_viewport_without_horizontal_overflow(1440)

    review_card = find("[data-receipt-review-notes-card]")
    review_card.find("[data-receipt-notes-summary]").click
    review_card.find("a[data-review-reason-target-adjustment='#{target_id}']").click

    expect_adjustment_row_expanded(row, target_id)
    expect_visible_adjustment_toggle_focused(row)
    expect_viewport_without_horizontal_overflow(1440)
    expect_browser_console_clean
  end

  it "調整行のreview reasonリンクをダブルクリックしてもフォームを送信しない" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "ダブルクリック確認店",
      purchased_at: Time.zone.local(2026, 7, 12, 12, 0, 0),
      payment_method: "cash",
      subtotal_amount: 100,
      tax_amount: 10,
      total_amount: 110
    )
    adjustment = create(
      :receipt_adjustment,
      receipt: receipt,
      label: "ダブルクリック対象調整",
      needs_review: true,
      review_reasons: [ "adjustment_uncertain" ]
    )
    receipt.update!(status: "review_needed", review_reasons: [])
    lock_version = receipt.lock_version

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")

    target_id = receipt_adjustment_target_id(adjustment)
    review_card = find("[data-receipt-review-notes-card]")
    review_card.find("[data-receipt-notes-summary]").click
    wait_for_visual_motion_to_finish(review_card)
    target_link = review_card.find("a[data-review-reason-target-adjustment='#{target_id}']")
    page.driver.browser.action.move_to(target_link.native).click.pause(duration: 0.2).click.perform

    expect(page).to have_current_path(edit_receipt_path(receipt), ignore_query: true)
    expect(page.evaluate_script("window.location.hash")).to eq("##{target_id}")
    expect(receipt.reload.lock_version).to eq(lock_version)
    expect_adjustment_row_expanded(receipt_adjustment_row(adjustment), target_id)
    expect_mobile_viewport_without_horizontal_overflow
    expect_browser_console_clean
  end

  it "調整行のhashから別画面へ移動して戻っても編集画面を復元する" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "履歴復元確認店",
      purchased_at: Time.zone.local(2026, 7, 13, 12, 0, 0),
      payment_method: "cash",
      subtotal_amount: 100,
      tax_amount: 10,
      total_amount: 110
    )
    adjustment = create(
      :receipt_adjustment,
      receipt: receipt,
      label: "履歴復元対象調整",
      needs_review: true,
      review_reasons: [ "adjustment_uncertain" ]
    )
    second_adjustment = create(
      :receipt_adjustment,
      receipt: receipt,
      label: "履歴復元対象調整2",
      needs_review: true,
      review_reasons: [ "adjustment_uncertain" ]
    )
    receipt.update!(status: "review_needed", review_reasons: [])

    sign_in_through_browser(user)
    target_id = receipt_adjustment_target_id(adjustment)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")

    review_card = find("[data-receipt-review-notes-card]")
    review_card.find("[data-receipt-notes-summary]").click
    review_card.find("a[data-review-reason-target-adjustment='#{target_id}']").click
    second_target_id = receipt_adjustment_target_id(second_adjustment)
    review_card.find("a[data-review-reason-target-adjustment='#{second_target_id}']").click
    review_card.find("a[data-review-reason-target-adjustment='#{target_id}']").click
    expect(page.evaluate_script("window.location.hash")).to eq("##{target_id}")
    expect(page.evaluate_script("Boolean(window.history.state?.turbo)")).to be(true)

    find("a[href='#{settings_path}']", visible: true).click
    expect(page).to have_current_path(settings_path)

    page.go_back
    expect(page).to have_current_path(edit_receipt_path(receipt), ignore_query: true)
    wait_for_stimulus_controller("receipt-form")

    row = receipt_adjustment_row(adjustment)
    expect_adjustment_row_expanded(row, target_id)
    expect(element_has_focus?(visible_adjustment_toggle(row))).to be(false)
    expect_mobile_viewport_without_horizontal_overflow
    expect_browser_console_clean
  end

  it "390pxで新規明細のcategoryをkeyboard選択し、422後もlabelと選択値を保持する" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "カテゴリ入力確認店",
      purchased_at: Time.zone.local(2026, 8, 7, 12, 0, 0),
      payment_method: "cash",
      subtotal_amount: 100,
      tax_amount: 0,
      total_amount: 100
    )
    receipt.receipt_items.create!(
      confirmed_name: "既存分類商品",
      category: "other",
      price: 100,
      quantity: 1,
      quantity_unit_code: "each",
      line_total: 100,
      needs_review: false
    )
    queue_adapter = ActiveJob::Base.queue_adapter
    queued_job_count = queue_adapter.enqueued_jobs.size

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")

    existing_row = expand_receipt_item_row(
      all("[data-receipt-form-target='itemRow']", visible: :all).first
    )
    existing_category = expect_category_label_association(existing_row)
    option_contract = existing_category.all("option", visible: :all).to_h do |option|
      [ option.value, option.text(:all) ]
    end

    aggregate_failures do
      expect(existing_category.value).to eq("other")
      expect(option_contract.fetch("")).to eq(I18n.t("receipts.item_fields.uncategorized"))
      expect(option_contract.fetch("other")).to eq(I18n.t("enums.receipt_item.category.other"))
    end

    click_button I18n.t("receipts.form.buttons.add_item")
    new_row = expand_receipt_item_row(
      all("[data-receipt-form-target='itemRow']", visible: :all).last
    )
    new_row.find("input[name$='[confirmed_name]']").set("新規分類商品")
    new_row.find("input[name$='[price]']").set("1e2")
    new_category = expect_category_label_association(new_row)
    select_with_keyboard(new_category, "medical")

    click_mobile_save_button

    expect(page).to have_content(I18n.t("receipts.form.errors.invalid_numeric_input"))
    expect_only_validation_failure_in_browser_console(receipt)
    retained_row = all("[data-receipt-form-target='itemRow']", visible: :all).find do |row|
      row.find("input[name$='[confirmed_name]']", visible: :all).value == "新規分類商品"
    end
    retained_row = expand_receipt_item_row(retained_row)
    retained_category = expect_category_label_association(retained_row)

    aggregate_failures do
      expect(retained_category.value).to eq("medical")
      expect(receipt.reload.receipt_items.count).to eq(1)
      expect(receipt.receipt_items.sole.category).to eq("other")
      expect(queue_adapter.enqueued_jobs.size).to eq(queued_job_count)
    end
    expect_mobile_viewport_without_horizontal_overflow
  end

  it "desktopで保存済みcategoryをkeyboard変更し、reloadとbrowser backで復元する" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "カテゴリ履歴確認店",
      purchased_at: Time.zone.local(2026, 8, 7, 13, 0, 0),
      payment_method: "cash",
      subtotal_amount: 200,
      tax_amount: 0,
      total_amount: 200
    )
    item = receipt.receipt_items.create!(
      confirmed_name: "履歴確認商品",
      category: "food",
      price: 200,
      quantity: 1,
      quantity_unit_code: "each",
      line_total: 200,
      needs_review: false
    )

    sign_in_through_browser(user)
    set_viewport(width: 1440, height: 1000, mobile: false)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")

    item_row = expanded_receipt_item_row
    category_select = expect_category_label_association(item_row)
    expect(category_select.value).to eq("food")
    select_with_keyboard(category_select, "other")
    click_button I18n.t("receipts.form.buttons.save"), match: :first

    expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
    expect(item.reload.category).to eq("other")

    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    expect(expect_category_label_association(expanded_receipt_item_row).value).to eq("other")
    page.refresh
    wait_for_stimulus_controller("receipt-form")
    expect(expect_category_label_association(expanded_receipt_item_row).value).to eq("other")

    page.execute_script("window.history.pushState({ categoryTest: true }, '', '#category-history')")
    expect(page.evaluate_script("window.location.hash")).to eq("#category-history")
    page.go_back
    expect(page).to have_current_path(edit_receipt_path(receipt), ignore_query: true)
    expect(page.evaluate_script("window.location.hash")).to eq("")
    wait_for_stimulus_controller("receipt-form")
    expect(expect_category_label_association(expanded_receipt_item_row).value).to eq("other")
    page.go_forward
    expect(page).to have_current_path(edit_receipt_path(receipt), ignore_query: true)
    expect(page.evaluate_script("window.location.hash")).to eq("#category-history")
    expect(expect_category_label_association(expanded_receipt_item_row).value).to eq("other")

    expect_viewport_without_horizontal_overflow(1440)
    expect_browser_console_clean
  end

  it "数量・単位・単価のmobile表示を維持しdesktopで欠けずに操作できる" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "数量単位表示確認店",
      purchased_at: Time.zone.local(2026, 8, 9, 10, 0, 0),
      payment_method: "cash",
      subtotal_amount: 14_808,
      tax_amount: 0,
      total_amount: 14_808
    )
    receipt.receipt_items.create!(
      confirmed_name: "数量単位表示確認商品",
      price: 1_234,
      quantity: 12,
      quantity_unit_code: "set",
      line_total: 14_808,
      needs_review: false
    )

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    row = expanded_receipt_item_row
    quantity_input = row.find_field(I18n.t("receipts.item_fields.quantity"), visible: :all)
    unit_select = row.find_field(I18n.t("receipts.item_fields.unit"), visible: :all)
    price_input = row.find_field(I18n.t("receipts.item_fields.unit_price"), visible: :all)

    page.execute_script(<<~JAVASCRIPT, quantity_input, price_input, SystemSettings::AMOUNT_LIMIT_CONFIGURABLE_MAX.to_s)
      arguments[0].value = arguments[0].max
      arguments[1].value = arguments[2]
    JAVASCRIPT

    aggregate_failures do
      expect(row.find_field(I18n.t("receipts.item_fields.quantity"), visible: :all)).to be_present
      expect(row.find_field(I18n.t("receipts.item_fields.unit"), visible: :all)).to be_present
      expect(row.find_field(I18n.t("receipts.item_fields.unit_price"), visible: :all)).to be_present
    end

    viewports = [
      { width: 320, height: 568, mobile: true, stacked_unit: true },
      { width: 359, height: 780, mobile: true, stacked_unit: true },
      { width: 360, height: 800, mobile: true },
      { width: 390, height: 844, mobile: true },
      { width: 430, height: 932, mobile: true },
      { width: 667, height: 375, mobile: true },
      { width: 767, height: 430, mobile: true },
      { width: 768, height: 900, mobile: false },
      { width: 844, height: 390, mobile: true },
      { width: 1024, height: 900, mobile: false },
      { width: 1440, height: 1000, mobile: false }
    ]

    viewports.each do |viewport|
      set_viewport(**viewport.slice(:width, :height, :mobile))
      wait_for_visual_motion_to_finish(row)
      metrics = quantity_unit_layout_metrics(row)

      aggregate_failures "viewport #{viewport.fetch(:width)}px" do
        expect(metrics.fetch("viewportWidth")).to eq(viewport.fetch(:width))
        expect(metrics.fetch("unitSelectWidth") + 1).to be >= metrics.fetch("requiredUnitSelectWidth")
        expect(metrics.fetch("unitSelectWithinWrapper")).to be(true)
        if viewport[:stacked_unit]
          expect(metrics.fetch("unitOnSameLine")).to be(false)
          expect(metrics.fetch("unitBelowQuantity")).to be(true)
        else
          expect(metrics.fetch("unitOnSameLine")).to be(true)
        end
        expect(metrics.fetch("unitTextAlign")).to eq("center")
        expect(metrics.fetch("unitTextAlignLast")).to eq("center")
        expect(metrics.fetch("visibleQuantityContentWidth") + 1).to be >= metrics.fetch("requiredQuantityContentWidth")
        expect(metrics.fetch("visiblePriceContentWidth") + 1).to be >= metrics.fetch("requiredPriceContentWidth")
        expect(metrics.fetch("priceControlsDoNotOverlap")).to be(true)
        if viewport.fetch(:width) <= 767
          expect(metrics.fetch("visiblePriceButtonCount")).to eq(2)
          expect(metrics.fetch("visiblePriceButtonWidths")).to all(be_within(1).of(40))
          expect(metrics.fetch("quantityBeforePriceWithoutOverlap")).to be(true)
        else
          expect(metrics.fetch("visiblePriceButtonCount")).to eq(0)
        end
        expect(metrics.fetch("horizontalOverflow")).to be(false)
      end
    end

    unit_select = row.find_field(I18n.t("receipts.item_fields.unit"), visible: :all)
    page.execute_script(<<~JAVASCRIPT, unit_select)
      (() => {
        const select = arguments[0]
        const option = new Option("パッケージあたり", "future_long_unit", true, true)
        select.add(option)
        select.value = option.value
      })()
    JAVASCRIPT

    viewports.select { |viewport| viewport.fetch(:mobile) }.each do |viewport|
      set_viewport(**viewport.slice(:width, :height, :mobile))
      wait_for_visual_motion_to_finish(row)
      metrics = quantity_unit_layout_metrics(row)

      aggregate_failures "long unit label at #{viewport.fetch(:width)}px" do
        expect(metrics.fetch("viewportWidth")).to eq(viewport.fetch(:width))
        expect(metrics.fetch("unitSelectWidth") + 1).to be >= metrics.fetch("requiredUnitSelectWidth")
        expect(metrics.fetch("unitSelectWithinWrapper")).to be(true)
        expect(metrics.fetch("unitTextAlign")).to eq("center")
        expect(metrics.fetch("unitTextAlignLast")).to eq("center")
        if viewport[:stacked_unit]
          expect(metrics.fetch("unitOnSameLine")).to be(false)
          expect(metrics.fetch("unitBelowQuantity")).to be(true)
        else
          expect(metrics.fetch("unitOnSameLine") || metrics.fetch("unitBelowQuantity")).to be(true)
        end
        expect(metrics.fetch("visibleQuantityContentWidth") + 1).to be >= metrics.fetch("requiredQuantityContentWidth")
        expect(metrics.fetch("visiblePriceContentWidth") + 1).to be >= metrics.fetch("requiredPriceContentWidth")
        expect(metrics.fetch("priceControlsDoNotOverlap")).to be(true)
        if viewport.fetch(:width) <= 767
          expect(metrics.fetch("visiblePriceButtonCount")).to eq(2)
          expect(metrics.fetch("visiblePriceButtonWidths")).to all(be_within(1).of(40))
          expect(metrics.fetch("quantityBeforePriceWithoutOverlap")).to be(true)
        else
          expect(metrics.fetch("visiblePriceButtonCount")).to eq(0)
        end
        expect(metrics.fetch("horizontalOverflow")).to be(false)
      end
    end

    page.execute_script(<<~JAVASCRIPT, quantity_input, price_input)
      arguments[0].value = "12"
      arguments[1].value = "1234"
    JAVASCRIPT

    select_with_keyboard(unit_select, "liter")
    aggregate_failures do
      expect(quantity_input["step"]).to eq("0.001")
      expect(quantity_input["inputmode"]).to eq("decimal")
    end
    unit_select.select(I18n.t("enums.receipt_item.quantity_unit_code.set"))
    aggregate_failures do
      expect(unit_select.value).to eq("set")
      expect(quantity_input["step"]).to eq("1")
      expect(quantity_input["inputmode"]).to eq("numeric")
    end

    expect_browser_console_clean
  end

  it "追従金額サマリーを320pxからdesktopまで一つの保存操作で表示する" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "追従金額確認",
      subtotal_amount: 100,
      tax_amount: 0,
      total_amount: 100,
      payment_method: "cash"
    )
    receipt.receipt_items.create!(
      confirmed_name: "表示確認明細",
      price: 100,
      quantity: 1,
      quantity_unit_code: "each",
      tax_rate: 0,
      line_total: 100,
      needs_review: false
    )
    receipt.receipt_adjustments.create!(
      kind: "point_usage",
      label: "ポイント利用",
      amount: 10,
      sign: "discount",
      source: "manual",
      needs_review: false,
      review_reasons: [],
      position_index: 0
    )

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    wait_for_stimulus_controller("mobile-amount-summary")

    maximum_amount_text = "¥#{SystemSettings::AMOUNT_LIMIT_CONFIGURABLE_MAX.to_s.reverse.scan(/.{1,3}/).join(",").reverse}"
    viewports = [
      { width: 320, height: 568, mobile: true },
      { width: 320, height: 844, mobile: true },
      { width: 390, height: 844, mobile: true },
      { width: 430, height: 932, mobile: true },
      { width: 767, height: 900, mobile: true },
      { width: 768, height: 900, mobile: false },
      { width: 1023, height: 900, mobile: false },
      { width: 1024, height: 900, mobile: false }
    ]

    viewports.each do |viewport|
      set_viewport(**viewport.slice(:width, :height, :mobile))
      summary = find("[data-controller~='mobile-amount-summary']", visible: :all)
      wait_for_visual_motion_to_finish(summary)
      displayed_amount = viewport.fetch(:width) < 1024 ? maximum_amount_text : "¥100"
      metrics = mobile_amount_summary_metrics(maximum_amount_text: displayed_amount)

      aggregate_failures "amount summary at #{viewport.fetch(:width)}x#{viewport.fetch(:height)}px" do
        expect(metrics.fetch("viewportWidth")).to eq(viewport.fetch(:width))
        expect(metrics.fetch("viewportHeight")).to eq(viewport.fetch(:height))
        expect(metrics.fetch("visibleSaveButtonCount")).to eq(1)
        expect(metrics.fetch("horizontalOverflow")).to be(false)
        expect(metrics.fetch("titleText")).to eq(I18n.t("receipts.common.total_amount_title"))
        expect(metrics.fetch("titleVisible")).to be(true)
        expect(metrics.fetch("titleAboveAmount")).to be(true)
        expect(metrics.fetch("decorationVisible")).to be(true)
        expect(metrics.fetch("decorationParentIsSummary")).to be(true)
        expected_decoration_top = viewport.fetch(:width) < 768 ? -48 : -16
        expect(metrics.fetch("decorationTopOffset")).to be_within(1).of(expected_decoration_top)
        expect(metrics.fetch("decorationIconWidth")).to be_within(1).of(120)
        expect(metrics.fetch("decorationIconHeight")).to be_within(1).of(120)
        expect(metrics.fetch("decorationIconFontSize")).to be_within(1).of(120)
        expect(metrics.fetch("decorationIntersectionWidth")).to be >= 24
        expect(metrics.fetch("decorationIntersectionHeight")).to be >= 24
        expect(metrics.fetch("amountLeftInset")).to be >= 10
        expect(metrics.fetch("headingRightInset")).to be >= 10

        if viewport.fetch(:width) < 1024
          expect(metrics.fetch("decorationRightOffset")).to be <= -55
          expect(metrics.fetch("decorationWidthBeforeSave")).to be >= 64
          expect(metrics.fetch("amountText")).to eq(maximum_amount_text)
          expect(metrics.fetch("amountTitle")).to eq(maximum_amount_text)
          expect(metrics.fetch("amountTextOverflow")).to eq("ellipsis")
          expect(metrics.fetch("amountClipped")).to be(false), metrics.inspect if viewport.fetch(:width) > 320
          expect(metrics.fetch("summaryPosition")).to eq("fixed")
          expect(metrics.fetch("amountBeforeControls")).to be(true)
          expect(metrics.fetch("summaryInsideViewport")).to be(true), metrics.inspect
          expect(metrics.fetch("controlsInsideSummary")).to be(true), metrics.inspect
          expect(metrics.fetch("controlsInsideViewport")).to be(true), metrics.inspect
          expect(metrics.fetch("saveRightInset")).to be >= 7
          expect(metrics.fetch("memoImageGap")).to be_between(20, 28)
        else
          expect(metrics.fetch("decorationRightOffset")).to be_within(1).of(16)
          expect(metrics.fetch("summaryPosition")).not_to eq("fixed")
          expect(metrics.fetch("detailsHidden")).to eq("false")
          expect(metrics.fetch("detailsInert")).to be(false)
        end

        if viewport.fetch(:width) < 768
          expect(metrics.fetch("detailsHidden")).to eq("true")
          expect(metrics.fetch("detailsInert")).to be(true)
          expect(metrics.fetch("detailsHeight")).to be <= 1
          expect(metrics.fetch("toggleExpanded")).to eq("false")
          expect(metrics.fetch("toggleVisible")).to be(true)
          expect(metrics.fetch("toggleWidth")).to be_within(1).of(44)
          expect(metrics.fetch("toggleHeight")).to be_within(1).of(44)
          expect(metrics.fetch("toggleBackground")).to eq("rgba(0, 0, 0, 0)")
          expect(metrics.fetch("toggleBorderWidth")).to eq("0px")
          expect(metrics.fetch("toggleBoxShadow")).to eq("none")
          expect(metrics.fetch("navVisible")).to be(true)
          expect(metrics.fetch("summaryAboveNav")).to be(true), metrics.inspect
        elsif viewport.fetch(:width) < 1024
          expect(metrics.fetch("detailsHidden")).to eq("false")
          expect(metrics.fetch("detailsInert")).to be(false)
          expect(metrics.fetch("detailsHeight")).to be > 1
          expect(metrics.fetch("toggleExpanded")).to eq("true")
          expect(metrics.fetch("toggleVisible")).to be(false)
          expect(metrics.fetch("primaryDetailsHorizontal")).to be(true)
          expect(metrics.fetch("paymentAdjustmentVisible")).to be(true)
          expect(metrics.fetch("finalPaymentVisible")).to be(true)
          expect(metrics.fetch("summaryHeight")).to be > metrics.fetch("compactHeight") + 100
          expect(metrics.fetch("visibleSaveButtonWidth")).to be >= 119
          expect(metrics.fetch("tabletDividerTopGap")).to be >= 15
          expect(metrics.fetch("tabletDividerBottomGap")).to be >= 15
          expect(metrics.fetch("navVisible")).to be(false)
          expect(metrics.fetch("summaryAtViewportBottom")).to be(true), metrics.inspect

          page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")
          wait_for_visual_motion_to_finish(summary)
          bottom_metrics = mobile_amount_summary_metrics(maximum_amount_text: maximum_amount_text)
          expect(bottom_metrics.fetch("imagePreviewClearance")).to be_between(23, 32), bottom_metrics.inspect
          expect(bottom_metrics.fetch("measuredSummaryHeight")).to be_within(1).of(bottom_metrics.fetch("summaryHeight"))
          expect(bottom_metrics.fetch("formContentPaddingBottom")).to be_within(1).of(bottom_metrics.fetch("summaryHeight"))
          page.execute_script("window.scrollTo(0, 0)")
        else
          expect(metrics.fetch("navVisible")).to be(false)
        end
      end
    end
  end

  it "内訳を上向きに展開し入力中は金額だけを追従表示する" do
    user = create_system_test_user
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: "金額内訳確認",
      subtotal_amount: 100,
      tax_amount: 0,
      total_amount: 100,
      payment_method: "cash"
    )
    receipt.receipt_items.create!(
      confirmed_name: "内訳確認明細",
      price: 100,
      quantity: 1,
      quantity_unit_code: "each",
      tax_rate: 0,
      line_total: 100,
      needs_review: false
    )

    sign_in_through_browser(user)
    visit edit_receipt_path(receipt)
    wait_for_stimulus_controller("receipt-form")
    wait_for_stimulus_controller("mobile-amount-summary")

    summary = find("[data-controller~='mobile-amount-summary']")
    toggle = summary.find("[data-mobile-amount-summary-target='toggle']")
    details = summary.find("[data-mobile-amount-summary-target='details']", visible: :all)
    save_button = summary.find(".receipt-amount-summary-save")
    nav = find("[data-mobile-ui-target='nav']")
    nav_root = find("#mobile-bottom-nav")

    wait_for_visual_motion_to_finish(summary)
    closed_metrics = mobile_amount_summary_metrics
    toggle.click
    wait_for_visual_motion_to_finish(summary)
    open_metrics = mobile_amount_summary_metrics
    aggregate_failures do
      expect(toggle["aria-expanded"]).to eq("true")
      expect(details["aria-hidden"]).to eq("false")
      expect(page.evaluate_script("arguments[0].inert", details)).to be(false)
      expect(details).to have_text(I18n.t("shared.amount_summary_card.subtotal"))
      expect(details).to have_text(I18n.t("shared.amount_summary_card.tax_amount"))
      expect(page.evaluate_script("document.activeElement === arguments[0]", toggle)).to be(true)
      expect(open_metrics.fetch("dividerBelowDetails")).to be(true)
      expect(open_metrics.fetch("dividerBeforeToolbar")).to be(true)
      expect(open_metrics.fetch("phoneDividerTopGap")).to be >= 15
      expect(open_metrics.fetch("phoneDividerBottomGap")).to be >= 15
      expect(open_metrics.fetch("decorationParentIsSummary")).to be(true)
      expect(open_metrics.fetch("decorationTopOffset")).to be_within(1).of(-16)
      expect(open_metrics.fetch("decorationRightOffset")).to be <= -55
      expect(open_metrics.fetch("decorationWidthBeforeSave")).to be >= 64
      expect(open_metrics.fetch("decorationTop")).to(
        be < closed_metrics.fetch("decorationTop") - 40,
        "closed=#{closed_metrics.inspect}\nopen=#{open_metrics.inspect}"
      )
      expect(open_metrics.fetch("decorationIntersectionWidth")).to be >= 24
      expect(open_metrics.fetch("decorationIntersectionHeight")).to be >= 24
      expect(open_metrics.fetch("decorationIconWidth")).to be_within(1).of(120)
      expect(open_metrics.fetch("decorationIconHeight")).to be_within(1).of(120)
      expect(open_metrics.fetch("decorationIconFontSize")).to be_within(1).of(120)
      expect(open_metrics.fetch("decorationIconIntersectionWidth")).to be >= 64
      expect(open_metrics.fetch("decorationIconIntersectionHeight")).to be >= 64
    end

    store_name = find_field(I18n.t("receipts.form.fields.store_name"))
    store_name.click
    focus_only_metrics = mobile_amount_summary_metrics
    aggregate_failures "software keyboard未確認のfocusでは表示を変えない" do
      expect(summary["data-mobile-amount-summary-keyboard-visible"]).to eq("false")
      expect(toggle).to be_visible
      expect(save_button).to be_visible
      expect(details["aria-hidden"]).to eq("false")
      expect(page.evaluate_script("arguments[0].inert", details)).to be(false)
      expect(nav["aria-hidden"]).to be_nil
      expect(focus_only_metrics.fetch("summaryTop")).to be_within(1).of(open_metrics.fetch("summaryTop"))
    end
    set_viewport(width: 390, height: 544, mobile: true)
    expect(page).to have_css(
      "[data-controller~='mobile-amount-summary']" \
      "[data-mobile-amount-summary-keyboard-visible='true']"
    )
    amount_above_keyboard = page.evaluate_async_script(<<~JAVASCRIPT, summary, Capybara.default_max_wait_time * 1000)
      const summary = arguments[0]
      const timeoutMilliseconds = arguments[1]
      const done = arguments[arguments.length - 1]
      const deadline = window.performance.now() + timeoutMilliseconds
      const check = () => {
        const viewport = window.visualViewport
        const viewportBottom = viewport ? viewport.offsetTop + viewport.height : window.innerHeight
        if (Math.abs(summary.getBoundingClientRect().bottom - (viewportBottom - 8)) <= 2) {
          done(true)
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
    wait_for_visual_motion_to_finish(summary)
    keyboard_metrics = mobile_amount_summary_metrics
    aggregate_failures do
      expect(amount_above_keyboard).to be(true)
      expect(toggle).not_to be_visible
      expect(save_button).not_to be_visible
      expect(details["aria-hidden"]).to eq("true")
      expect(page.evaluate_script("arguments[0].inert", details)).to be(true)
      expect(nav["class"]).to include("translate-y-full", "pointer-events-none")
      expect(nav_root["class"]).to include("pointer-events-none")
      expect(nav["aria-hidden"]).to eq("true")
      expect(page.evaluate_script("arguments[0].inert", nav)).to be(true)
      expect(summary.find("[data-receipt-form-target='totalAmount']")).to be_visible
      expect(keyboard_metrics.fetch("titleVisible")).to be(true)
      expect(keyboard_metrics.fetch("titleAboveAmount")).to be(true)
      expect(keyboard_metrics.fetch("decorationVisible")).to be(true)
      expect(keyboard_metrics.fetch("decorationIconFontSize")).to be_within(1).of(120)
      expect(keyboard_metrics.fetch("summaryHeight")).to be_within(1).of(keyboard_metrics.fetch("compactHeight"))
      expect(keyboard_metrics.fetch("summaryHeight")).to be_within(1).of(closed_metrics.fetch("summaryHeight"))
      expect(keyboard_metrics.fetch("toolbarHeight")).to be_within(1).of(closed_metrics.fetch("toolbarHeight"))
    end

    set_viewport(width: 390, height: 844, mobile: true)
    expect(page).to have_css(
      "[data-controller~='mobile-amount-summary']" \
      "[data-mobile-amount-summary-keyboard-visible='false']"
    )
    page.execute_script("document.activeElement.blur()")
    wait_for_visual_motion_to_finish(summary)
    restored_metrics = mobile_amount_summary_metrics
    aggregate_failures do
      expect(save_button).to be_visible
      expect(toggle).to be_visible
      expect(toggle["aria-expanded"]).to eq("false")
      expect(nav["class"]).not_to include("translate-y-full", "pointer-events-none")
      expect(nav_root["class"]).not_to include("pointer-events-none")
      expect(nav["aria-hidden"]).to be_nil
      expect(page.evaluate_script("arguments[0].inert", nav)).to be(false)
      expect(restored_metrics.fetch("summaryAboveNav")).to be(true)
    end

    toggle.send_keys(:enter)
    expect(toggle["aria-expanded"]).to eq("true")
    page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")
    expect(summary).to be_visible
    page.execute_script("window.scrollTo(0, 0)")
    expect(summary).to be_visible

    item_row = expanded_receipt_item_row
    item_row.find("[data-receipt-form-target='priceInput']").set("250")
    expect(summary.find("[data-receipt-form-target='totalAmount']")).to have_text("¥250")
    expect_mobile_viewport_without_horizontal_overflow

    set_viewport(width: 768, height: 900, mobile: false)
    wait_for_visual_motion_to_finish(summary)
    aggregate_failures do
      expect(toggle).not_to be_visible
      expect(details["aria-hidden"]).to eq("false")
      expect(page.evaluate_script("arguments[0].inert", details)).to be(false)
    end

    store_name.click
    tablet_focus_only_metrics = mobile_amount_summary_metrics
    aggregate_failures "tabletでもsoftware keyboard未確認のfocusでは表示を変えない" do
      expect(summary["data-mobile-amount-summary-keyboard-visible"]).to eq("false")
      expect(save_button).to be_visible
      expect(details["aria-hidden"]).to eq("false")
      expect(page.evaluate_script("arguments[0].inert", details)).to be(false)
      expect(tablet_focus_only_metrics.fetch("summaryPosition")).to eq("fixed")
    end
    set_viewport(width: 768, height: 600, mobile: false)
    expect(page).to have_css(
      "[data-controller~='mobile-amount-summary']" \
      "[data-mobile-amount-summary-keyboard-visible='true']"
    )
    wait_for_visual_motion_to_finish(summary)
    tablet_keyboard_metrics = mobile_amount_summary_metrics
    aggregate_failures do
      expect(details["aria-hidden"]).to eq("true")
      expect(page.evaluate_script("arguments[0].inert", details)).to be(true)
      expect(save_button).not_to be_visible
      expect(toggle).not_to be_visible
      expect(nav["aria-hidden"]).to eq("true")
      expect(page.evaluate_script("arguments[0].inert", nav)).to be(true)
      expect(nav_root["class"]).to include("pointer-events-none")
      expect(summary.find("[data-receipt-form-target='totalAmount']")).to be_visible
      expect(tablet_keyboard_metrics.fetch("titleVisible")).to be(true)
      expect(tablet_keyboard_metrics.fetch("decorationVisible")).to be(true)
      expect(tablet_keyboard_metrics.fetch("decorationIconFontSize")).to be_within(1).of(120)
      expect(tablet_keyboard_metrics.fetch("summaryHeight")).to be_within(1).of(tablet_keyboard_metrics.fetch("compactHeight"))
      expect(tablet_keyboard_metrics.fetch("toolbarHeight")).to be >= 44
      expect(tablet_keyboard_metrics.fetch("detailsHeight")).to be <= 1
      expect(tablet_keyboard_metrics.fetch("visibleSaveButtonCount")).to eq(0)
      expect(tablet_keyboard_metrics.fetch("horizontalOverflow")).to be(false)
      expect(tablet_keyboard_metrics.fetch("measuredSummaryHeight")).to be_within(1).of(tablet_keyboard_metrics.fetch("summaryHeight"))
      expect(tablet_keyboard_metrics.fetch("formContentPaddingBottom")).to be_within(1).of(tablet_keyboard_metrics.fetch("summaryHeight"))
    end
    set_viewport(width: 768, height: 900, mobile: false)
    expect(page).to have_css(
      "[data-controller~='mobile-amount-summary']" \
      "[data-mobile-amount-summary-keyboard-visible='false']"
    )
    page.execute_script("document.activeElement.blur()")
    wait_for_visual_motion_to_finish(summary)
    tablet_restored_metrics = mobile_amount_summary_metrics
    aggregate_failures do
      expect(details["aria-hidden"]).to eq("false")
      expect(page.evaluate_script("arguments[0].inert", details)).to be(false)
      expect(tablet_restored_metrics.fetch("measuredSummaryHeight")).to be_within(1).of(tablet_restored_metrics.fetch("summaryHeight"))
      expect(tablet_restored_metrics.fetch("formContentPaddingBottom")).to be_within(1).of(tablet_restored_metrics.fetch("summaryHeight"))
    end

    expect_browser_console_clean
  end
end
