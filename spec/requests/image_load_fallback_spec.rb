# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Image load fallback rendering", type: :request do
  let(:user) { create(:user, name: "Fallback User") }

  before do
    LegalDocuments::Sync.call
    sign_in user
  end

  it "renders avatars in a safe initial state with an accessible initials fallback" do
    user.avatar.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/receipt_sample.jpg")),
      filename: "avatar.jpg",
      content_type: "image/jpeg"
    )

    get settings_path

    document = Nokogiri::HTML(response.body)
    images = document.css("[data-avatar] img[data-image-load-state-target~='image']")
    fallbacks = document.css("[data-avatar] [data-image-load-state-target~='fallback']")

    aggregate_failures do
      expect(response).to have_http_status(:success)
      expect(images).to be_present
      expect(images).to all(satisfy { |image| image["class"].split.include?("hidden") })
      expect(images).to all(satisfy { |image| image["data-action"].include?("error->image-load-state#imageFailed") })
      expect(fallbacks).to be_present
      expect(fallbacks).to all(satisfy { |fallback| !fallback["class"].to_s.split.include?("hidden") })
      expect(fallbacks).to all(satisfy { |fallback| fallback["aria-label"] == I18n.t("shared.avatar.default_alt") })
    end
  end

  it "renders receipt load-error fallback and keeps preview/download safe until load succeeds" do
    receipt = create(:receipt, :completed, :with_image, user:)

    get receipt_path(receipt)

    document = Nokogiri::HTML(response.body)
    image_card = document.at_css("[data-controller~='receipt-image-card']")
    preview = image_card.at_css("[data-receipt-image-card-target~='previewTrigger']")
    preview_image = image_card.at_css("img[data-image-load-state-target~='image']")
    fallback = image_card.at_css("[data-image-load-state-target~='fallback']")
    download = image_card.at_css("[data-receipt-image-card-target~='download']")

    aggregate_failures do
      expect(response).to have_http_status(:success)
      expect(image_card["data-action"]).to include("image-load-state:unavailable->receipt-image-card#imageUnavailable")
      expect(preview["disabled"]).to eq("disabled")
      expect(preview["aria-disabled"]).to eq("true")
      expect(preview_image["class"].split).to include("hidden")
      expect(fallback["class"].split).to include("hidden")
      expect(fallback["role"]).to eq("status")
      expect(fallback.text).to include(I18n.t("shared.receipt_image_card.unavailable"))
      expect(download["class"].split).to include("hidden")
      expect(download["hidden"]).to eq("hidden")
      expect(download["aria-disabled"]).to eq("true")
      expect(response.body).not_to include(receipt.image.blob.key)
    end
  end

  it "keeps the attachment-none state distinct from a browser load failure" do
    receipt = create(:receipt, :completed, user:)

    get receipt_path(receipt)

    document = Nokogiri::HTML(response.body)
    image_card = document.at_css("[data-controller~='receipt-image-card']")

    aggregate_failures do
      expect(response).to have_http_status(:success)
      expect(image_card.text).to include(I18n.t("receipts.show.image_empty"))
      expect(image_card.text).not_to include(I18n.t("shared.receipt_image_card.unavailable"))
      expect(image_card.at_css("[data-image-load-state-target~='image']")).to be_nil
      expect(image_card.at_css("[data-receipt-image-card-target~='previewTrigger']")).to be_nil
      expect(image_card.at_css("[data-receipt-image-card-target~='download']")).to be_nil
    end
  end
end
