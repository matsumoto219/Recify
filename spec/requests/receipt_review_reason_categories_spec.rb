require "rails_helper"

RSpec.describe "Receipt review reason categories", type: :request do
  let(:user) { create(:user) }
  let(:receipt) do
    create(
      :receipt,
      user: user,
      status: "review_needed",
      purchased_at: nil,
      payment_method: nil,
      review_reasons: %w[purchased_at_missing payment_method_missing]
    )
  end

  before do
    sign_in user
  end

  it "showとeditで欠損項目を生成元ではなく確認内容として表示する" do
    [ receipt_path(receipt), edit_receipt_path(receipt) ].each do |path|
      get path

      document = Nokogiri::HTML(response.body)
      review_card = document.at_css("[data-receipt-review-notes-card]")

      aggregate_failures(path) do
        expect(response).to have_http_status(:success)
        expect(review_card).to be_present
        expect(review_card.text).to include("項目の確認")
        expect(review_card.text).to include(
          I18n.t("enums.receipt_item.review_reason.purchased_at_missing"),
          I18n.t("enums.receipt_item.review_reason.payment_method_missing")
        )
        expect(review_card.text).not_to include("AI補完")
      end
    end
  end
end
