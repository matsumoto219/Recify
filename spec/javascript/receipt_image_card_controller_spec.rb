# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Receipt image card Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/receipt_image_card_controller.js").read }

  it "opens the image preview from image review target hashes without toggling it closed" do
    aggregate_failures do
      expect(source).to include("reviewTarget: String")
      expect(source).to include("document.addEventListener('click', this.handleReviewTargetClick)")
      expect(source).to include("window.addEventListener('hashchange', this.handleReviewTargetHashChange)")
      expect(source).to include("this.openFromReviewTargetHash()")
      expect(source).to include("this.openPreview({ userDirected: true })")
      expect(source).to include("replaceReviewTargetHash")
      expect(source).to include("this.isOpen = true")
      expect(source).to include("return this.reviewTargetValue !== '' && targetId === this.reviewTargetValue")
      expect(source).to include("reviewScrollTarget")
      expect(source).to include("const section = document.getElementById(this.reviewTargetValue)")
      expect(source).to include("section.scrollIntoView({ behavior: 'auto', block: 'start', inline: 'nearest' })")
      expect(source).to include("centerReviewScrollTarget")
      expect(source).to include("window.scrollBy({ top: delta, behavior: 'smooth' })")
      expect(source).not_to include("IMAGE_PREVIEW_REVIEW_TARGET = 'receipt-section-image-preview'")
    end
  end

  it "replays same-hash image review links without relying on Turbo navigation" do
    aggregate_failures do
      expect(source).to include("if (window.location.hash !== this.reviewTargetHash(targetId))")
      expect(source).to include("event.preventDefault()")
      expect(source).to include("window.history.replaceState(null, '', path)")
      expect(source).to include("window.location.replace(`${path}${this.reviewTargetHash(targetId)}`)")
    end
  end

  it "keeps selected files and remove-image requests untouched while opening from review links" do
    open_from_review_target = source[/openFromReviewTarget \(\{ scroll = true \} = \{\}\) \{.*?^\s+\}/m]
    open_preview = source[/openPreview \(\{ userDirected = false \} = \{\}\) \{.*?^\s+\}/m]

    aggregate_failures do
      expect(open_from_review_target).to be_present
      expect(open_preview).to be_present
      expect(open_from_review_target).not_to include("clearFileInput")
      expect(open_from_review_target).not_to include("clearRemoveImageRequest")
      expect(open_preview).not_to include("clearFileInput")
      expect(open_preview).not_to include("clearRemoveImageRequest")
    end
  end

  it "disables image actions after a load failure and restores them only after a successful load" do
    aggregate_failures do
      expect(source).to include("imageUnavailable")
      expect(source).to include("imageAvailable")
      expect(source).to include("this.previewTriggerTarget.disabled = true")
      expect(source).to include("this.downloadTarget.removeAttribute('href')")
      expect(source).to include("this.downloadTarget.hidden = true")
      expect(source).to include("this.previewTriggerTarget.setAttribute('aria-label', this.unavailableImageLabelValue)")
      expect(source).to include("if (!this.imageIsAvailable) return")
      expect(source).to include("this.restoreImageControlsForCache()")
    end
  end
end
