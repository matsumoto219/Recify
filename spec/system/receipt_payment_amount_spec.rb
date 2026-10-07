require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "支払金額の未取得表示と編集", type: :system do
  [
    { name: "desktop", size: [ 1440, 1000 ], theme: "light" },
    { name: "mobile", size: [ 390, 844 ], theme: "dark" }
  ].each do |viewport|
    it "#{viewport[:name]}で未取得と0円を区別し、購入金額編集で支払額を変更しない", screen_size: viewport[:size] do
      user = create_system_test_user(theme_preference: viewport[:theme])
      receipt = create(
        :receipt,
        :completed,
        user: user,
        store_name: "支払編集確認店",
        subtotal_amount: 100,
        tax_amount: 0,
        total_amount: 100,
        payment_method: "other"
      )
      receipt.receipt_items.create!(
        confirmed_name: "確認商品",
        price: 100,
        quantity: 1,
        quantity_unit_code: "each",
        pricing_source_kind: "count_unit_price",
        input_tax_inclusion: "gross",
        tax_inclusion_origin: "manual",
        tax_rate: 0,
        original_line_total: 100,
        line_total: 100,
        needs_review: false,
        review_reasons: []
      )
      receipt.receipt_payments.create!(method: "現金", amount: 60)
      gift_payment = receipt.receipt_payments.create!(method: "eGift", amount: nil)

      visit new_user_session_path
      fill_in "user_email", with: user.email
      fill_in "user_password", with: "password"
      click_button I18n.t("auth.sessions.submit")
      expect(page).to have_current_path(receipts_path, ignore_query: true)
      visit edit_receipt_path(receipt)
      wait_for_stimulus_controller("receipt-form")
      expect(page).to have_css("html[data-theme='#{viewport[:theme]}']")

      payment_rows = all("[data-receipt-form-target='paymentsContainer'] [data-receipt-form-target='paymentRow']", count: 2)
      amount_input = payment_rows.last.find("[data-receipt-form-target='paymentAmountInput']")
      expect(amount_input.value).to eq("")
      expect(amount_input["placeholder"]).to eq(I18n.t("receipts.payment_fields.amount_unavailable"))
      expect(page).to have_css("[data-receipt-form-target='paymentAmountSum']", text: "—")
      expect(page).to have_css("[data-receipt-form-target='paymentDifferenceAmount']", text: "—")
      expect(page).to have_no_css("[data-receipt-form-target='paymentMismatchWarning']")

      amount_input.send_keys("0", :tab)
      expect(amount_input.value).to eq("0")
      expect(page).to have_css("[data-receipt-form-target='paymentAmountSum']", text: "¥60")
      expect(page).to have_css("[data-receipt-form-target='paymentDifferenceAmount']", text: "-¥40")
      expect(page).to have_css("[data-receipt-form-target='paymentMismatchWarning']")

      item_row = find("[data-receipt-form-target='itemRow']")
      item_row.find("[data-receipt-form-target='itemDetailsToggle']", match: :first).click
      price_input = item_row.find("[data-receipt-form-target='priceInput']")
      price_input.set("200")
      price_input.send_keys(:tab)
      expect(page).to have_css("[data-receipt-form-target='paymentReconciliationFinalAmount']", text: "¥200")
      expect(page).to have_css("[data-receipt-form-target='paymentDifferenceAmount']", text: "-¥140")
      expect(amount_input.value).to eq("0")
      overflow = page.evaluate_script("document.documentElement.scrollWidth > window.innerWidth")
      expect(overflow).to be(false)

      page.execute_script("document.activeElement?.blur()")
      find_button(I18n.t("receipts.form.buttons.save"), match: :first).click
      expect(page).to have_current_path(receipt_path(receipt), ignore_query: true)
      expect(receipt.reload.total_amount).to eq(200)
      expect(gift_payment.reload.amount).to eq(0)
      expect(receipt.receipt_payments.find_by!(method: "現金").amount).to eq(60)
      expect(receipt.review_reasons).to include("payment_amount_mismatch")

      visit edit_receipt_path(receipt)
      wait_for_stimulus_controller("receipt-form")
      expect(page).to have_css("[data-receipt-form-target='paymentAmountSum']", text: "¥60")
      expect(page).to have_css("[data-receipt-form-target='paymentDifferenceAmount']", text: "-¥140")
      expect_browser_console_clean
    end
  end
end
