require "rails_helper"

RSpec.describe Receipts::Editing do
  describe ".change_set" do
    it "既存change set入口へ委譲する" do
      allow(Receipts::Editing::ChangeSet).to receive(:call).and_return(:change_set)

      expect(described_class.change_set(receipt: :receipt, permitted: :permitted)).to eq(:change_set)
      expect(Receipts::Editing::ChangeSet).to have_received(:call).with(receipt: :receipt, permitted: :permitted)
    end
  end

  describe ".check_consistency" do
    it "既存consistency guard入口へ委譲する" do
      arguments = {
        receipt_items: [],
        receipt_adjustments: [],
        receipt_payments: [],
        amount_result: :amount_result
      }
      allow(Receipts::Editing::ConsistencyGuard).to receive(:call).and_return(:guard)

      expect(described_class.check_consistency(**arguments)).to eq(:guard)
      expect(Receipts::Editing::ConsistencyGuard).to have_received(:call).with(**arguments)
    end
  end

  describe ".review_state" do
    it "既存review state入口へ委譲する" do
      arguments = {
        receipt: :receipt,
        permitted: :permitted,
        amount_result: :amount_result,
        consistency_review_reasons: [],
        child_review_remaining: false,
        nested_amount_inputs_submitted: false,
        item_inputs_submitted: false
      }
      allow(Receipts::Editing::ReviewState).to receive(:call).and_return(:state)

      expect(described_class.review_state(**arguments)).to eq(:state)
      expect(Receipts::Editing::ReviewState).to have_received(:call).with(**arguments)
    end
  end

  describe ".item_review_state" do
    it "既存item review state入口へ委譲する" do
      arguments = { item: :item, submitted_attributes: {} }
      allow(Receipts::Editing::ReviewState).to receive(:item_review_state).and_return(:state)

      expect(described_class.item_review_state(**arguments)).to eq(:state)
      expect(Receipts::Editing::ReviewState).to have_received(:item_review_state).with(**arguments)
    end
  end
end
