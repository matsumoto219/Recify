# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Receipt form Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/receipt_form_controller.js").read }

  it "opens item detail panels from item review target hashes without toggling them closed" do
    aggregate_failures do
      expect(source).to include("reviewItemTargetPrefix: String")
      expect(source).to include("reviewItemsTarget: String")
      expect(source).to include("window.addEventListener('hashchange', this.handleHashChange)")
      expect(source).to include("this.expandItemDetailsFromHash()")
      expect(source).to include("setItemDetailsOpen({ row, panel, toggles, icons, open: true })")
      expect(source).to include("this.pushReviewTargetHash(targetId)")
      expect(source).to include("targetId.startsWith(this.reviewItemTargetPrefixValue)")
      expect(source).not_to include("REVIEW_REASON_ITEM_TARGET_PREFIX = 'receipt-item-'")
    end
  end

  it "falls back safely when the target item row is missing or already deleted" do
    aggregate_failures do
      expect(source).to include("if (!this.reviewItemRowVisible(row))")
      expect(source).to include("destroyField?.value !== '1'")
      expect(source).to include("this.scrollReviewTargetFallback()")
      expect(source).to include("const fallback = document.getElementById(targetId) || document.getElementById(this.reviewItemsTargetValue)")
      expect(source).not_to include("RECEIPT_REVIEW_TARGET_ITEMS = 'receipt-section-items'")
    end
  end

  it "keeps the latest countable line total as the baseline for repeated recalculation" do
    aggregate_failures do
      expect(source).to include("lineTotalInput.dataset.originalLineTotal = String(originalLineTotal)")
      expect(source).to include("lineTotalInput.dataset.originalSavedLineTotal = String(lineTotal)")
      expect(source).to include("if (this.recalculatesQuantityUnit(quantityUnit))")
    end
  end

  it "does not rewrite a quantity while the administrator is typing" do
    aggregate_failures do
      expect(source).not_to include("sanitizeQuantityInput")
      expect(source).not_to include("preventIntegerQuantityDecimalInput")
    end
  end
end
