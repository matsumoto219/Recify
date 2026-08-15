require "rails_helper"

RSpec.describe "Receipt mobile amount summary", type: :request do
  let(:user) { create(:user) }
  let(:receipt) do
    create(
      :receipt,
      user: user,
      store_name: "金額表示確認",
      subtotal_amount: 1_100,
      tax_amount: 100,
      total_amount: 1_200,
      payment_method: "cash",
      status: "review_needed"
    )
  end

  before do
    sign_in user
  end

  it "編集フォームだけに単一の追従金額サマリーとフォーム内保存を描画する" do
    get edit_receipt_path(receipt)

    document = Nokogiri::HTML(response.body)
    form = document.at_css("form[data-controller~='receipt-form']")
    summary = form.at_css(
      "##{ReceiptsHelper::RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY}" \
      "[data-controller~='mobile-amount-summary']"
    )
    toggle = summary.at_css("[data-mobile-amount-summary-target='toggle']")
    panel = summary.at_css("[data-mobile-amount-summary-target='details']")
    panel_inner = panel.at_css(".receipt-amount-summary-details-inner")
    save_button = summary.at_css("button.receipt-amount-summary-save[type='submit']")
    title = summary.at_css(".receipt-amount-summary-title")
    decoration = summary.at_css(".receipt-amount-summary-decoration")
    primary_details = summary.css(".receipt-amount-summary-primary-detail")
    aside = form.at_css(".receipt-form-aside")

    aggregate_failures do
      expect(response).to have_http_status(:success)
      expect(summary["class"].split).to include("scroll-mt-24")
      expect(form.css("[data-receipt-form-target='totalAmount']").size).to eq(1)
      expect(form.css("[data-receipt-form-target='subtotalAmount']").size).to eq(1)
      expect(form.css("[data-receipt-form-target='taxAmount']").size).to eq(1)
      expect(form.css("[data-receipt-form-target='taxRateSummary']").size).to eq(1)
      expect(toggle["type"]).to eq("button")
      expect(toggle["aria-controls"]).to eq(panel["id"])
      expect(toggle["aria-expanded"]).to eq("true")
      expect(toggle.at_css("[aria-hidden='true']")).to be_present
      expect(panel["aria-hidden"]).to eq("false")
      expect(panel.key?("inert")).to be(false)
      expect(panel_inner["class"].split).to include("token-scrollbar-brand")
      expect(title.text.strip).to eq(I18n.t("receipts.common.total_amount_title"))
      expect(summary["aria-labelledby"]).to eq(title["id"])
      expect(decoration["aria-hidden"]).to eq("true")
      expect(decoration.text.strip).to eq("payments")
      expect(decoration.parent).to eq(summary)
      expect(summary.at_css(".receipt-amount-summary-toolbar > .receipt-amount-summary-decoration")).to be_nil
      expect(primary_details.size).to eq(3)
      expect(aside.element_children.first["id"]).to eq(ReceiptsHelper::RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY)
      expect(form.at_css(".receipt-form-memo-card")).to be_present
      expect(save_button["form"]).to be_nil
      expect(save_button["data-turbo-confirm"]).to be_nil
      expect(document.css("[data-mobile-ui-target='actions']")).to be_empty
      expect(document.at_css("#mobile-bottom-nav").text).not_to include(I18n.t("receipts.form.buttons.save"))
    end
  end

  it "詳細画面は従来の静的金額カードを維持する" do
    get receipt_path(receipt)

    document = Nokogiri::HTML(response.body)
    total = document.at_css("[data-receipt-form-target='totalAmount']")
    summary = total.ancestors("section").first
    decoration = summary.at_css(".receipt-amount-summary-decoration")
    details = summary.at_css(".receipt-amount-summary-details")

    aggregate_failures do
      expect(response).to have_http_status(:success)
      expect(total.text.strip).to eq("¥1,200")
      expect(decoration.parent).to eq(summary)
      expect(decoration["aria-hidden"]).to eq("true")
      expect(decoration.text.strip).to eq("payments")
      expect(details["aria-hidden"]).to eq("false")
      expect(details["class"].split).not_to include("collapsible-grid")
      expect(document.css("[data-controller~='mobile-amount-summary']")).to be_empty
      expect(document.css("[data-mobile-amount-summary-target='toggle']")).to be_empty
      expect(document.css(".receipt-amount-summary-save")).to be_empty
    end
  end
end
