require "rails_helper"

RSpec.describe Receipts::Editing do
  describe ".create_manual" do
    it "manual create workflowへ委譲する" do
      arguments = { receipt: :receipt, attributes: :attributes, user: :user, items_missing: false }
      allow(Receipts::Editing::ManualCreator).to receive(:call).and_return(:result)

      expect(described_class.create_manual(**arguments)).to eq(:result)
      expect(Receipts::Editing::ManualCreator).to have_received(:call).with(**arguments)
    end
  end

  describe ".build_input" do
    it "既存input builder入口へ委譲する" do
      allow(Receipts::Editing::InputBuilder).to receive(:call).and_return(:input)

      expect(described_class.build_input(receipt: :receipt, permitted: :permitted)).to eq(:input)
      expect(Receipts::Editing::InputBuilder).to have_received(:call).with(receipt: :receipt, permitted: :permitted)
    end
  end

  describe Receipts::Editing::ConflictError do
    it "duplicate child metadataを公開Errorへ保持する" do
      error = described_class.new(attributes_key: "receipt_items_attributes", duplicate_ids: %w[7])

      expect(error).to have_attributes(
        attributes_key: "receipt_items_attributes",
        duplicate_ids: %w[7],
        message: "Duplicate nested child ids for receipt_items_attributes"
      )
    end
  end

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

  describe ".apply_amount_result!" do
    it "既存amount result applicator入口へ委譲する" do
      arguments = {
        receipt: :receipt,
        attributes: :attributes,
        amount_result: :amount_result,
        context: :manual,
        change_set: nil,
        tax_details_recalculated: false
      }
      allow(Receipts::Editing::AmountResultApplicator).to receive(:call).and_return(:attributes)

      expect(described_class.apply_amount_result!(**arguments)).to eq(:attributes)
      expect(Receipts::Editing::AmountResultApplicator).to have_received(:call).with(**arguments)
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
