require "rails_helper"

RSpec.describe Receipts::Processing do
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
