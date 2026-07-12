require "rails_helper"

RSpec.describe Receipts::Processing do
  describe ".admin_retry_eligibility" do
    it "SystemOperationsのread-only eligibility入口へ委譲する" do
      allow(SystemOperations).to receive(:receipt_analysis_retry_eligibility).and_return(:eligibility)

      result = described_class.admin_retry_eligibility(receipt: build_stubbed(:receipt), parent_run: nil)

      aggregate_failures do
        expect(result).to eq(:eligibility)
        expect(SystemOperations).to have_received(:receipt_analysis_retry_eligibility)
          .with(receipt: kind_of(Receipt), parent_run: nil)
      end
    end
  end

  describe ".admin_retry_types" do
    it "SystemOperationsの既存retry type一覧を公開する" do
      allow(SystemOperations).to receive(:receipt_analysis_retry_types).and_return(%w[full_reanalyze])

      expect(described_class.admin_retry_types).to eq(%w[full_reanalyze])
    end
  end

  describe ".finalize_decision_from_snapshot" do
    it "neutral contractのsnapshot parserへ委譲する" do
      snapshot = { schema_version: "v1", strategy: "ocr_only" }
      decision = instance_double(Receipts::Processing::Contracts::FinalizeDecision)
      allow(Receipts::Processing::Contracts::FinalizeDecision).to receive(:from_snapshot).and_return(decision)

      expect(described_class.finalize_decision_from_snapshot(snapshot)).to eq(decision)
      expect(Receipts::Processing::Contracts::FinalizeDecision).to have_received(:from_snapshot).with(snapshot)
    end
  end
end
