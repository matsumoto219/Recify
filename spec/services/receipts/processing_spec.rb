require "rails_helper"

RSpec.describe Receipts::Processing do
  describe "public contracts" do
    it "legacy workflowのErrorとResult contractを同一objectで公開する" do
      aggregate_failures do
        expect(described_class::AnalysisError).to equal(Receipts::Processing::Pipeline::AnalysisError)
        expect(described_class::EnqueueError).to equal(Receipts::Processing::Runs::EnqueueError)
        expect(described_class::Error).to equal(Receipts::Processing::Runs::Error)
        expect(described_class::InvalidTransition).to equal(Receipts::Processing::Runs::InvalidTransition)
        expect(described_class::Result).to equal(Receipts::Processing::Pipeline::Result)
        expect(described_class::StartResult).to equal(Receipts::Processing::Runs::StartResult)
        expect(described_class::TerminalRunError).to equal(Receipts::Processing::Runs::TerminalRunError)
      end
    end
  end

  describe "pipeline facade" do
    it "OCR stageをlegacy Pipelineへ委譲する" do
      run = instance_double(ReceiptAnalysisRun)
      allow(Receipts::Processing::Pipeline).to receive(:run_ocr).with(run).and_return(:result)

      expect(described_class.run_ocr(run)).to eq(:result)
    end
  end

  describe ".mark_processing!" do
    it "Processing所有のstatus transitionへ委譲する" do
      receipt = instance_double(Receipt)
      allow(Receipts::Processing::StatusTransition).to receive(:mark_processing!).and_return(true)

      expect(described_class.mark_processing!(receipt)).to eq(true)
      expect(Receipts::Processing::StatusTransition).to have_received(:mark_processing!).with(receipt)
    end
  end

  describe "run lifecycle facade" do
    it "run作成をlegacy Runsへ委譲する" do
      arguments = { receipt: instance_double(Receipt), source: "upload" }
      allow(Receipts::Processing::Runs).to receive(:start).with(**arguments).and_return(:result)

      expect(described_class.start(**arguments)).to eq(:result)
    end
  end

  describe ".admin_retry_eligibility" do
    it "private admin retry policyへ委譲する" do
      allow(Receipts::Processing::AdminRetryPolicy).to receive(:eligibility).and_return(:eligibility)

      result = described_class.admin_retry_eligibility(receipt: build_stubbed(:receipt), parent_run: nil)

      aggregate_failures do
        expect(result).to eq(:eligibility)
        expect(Receipts::Processing::AdminRetryPolicy).to have_received(:eligibility)
          .with(receipt: kind_of(Receipt), parent_run: nil)
      end
    end
  end

  describe ".admin_retry_types" do
    it "private admin retry policyのtype一覧を公開する" do
      expect(described_class.admin_retry_types).to eq(
        %w[full_reanalyze ocr_retry ai_retry finalize_retry]
      )
    end
  end

  describe ".admin_retry_decision" do
    it "private admin retry policyへ委譲する" do
      allow(Receipts::Processing::AdminRetryPolicy).to receive(:decision).and_return(:decision)

      result = described_class.admin_retry_decision(receipt: build_stubbed(:receipt), parent_run: nil, retry_type: "full_reanalyze")

      aggregate_failures do
        expect(result).to eq(:decision)
        expect(Receipts::Processing::AdminRetryPolicy).to have_received(:decision).with(
          receipt: kind_of(Receipt),
          parent_run: nil,
          retry_type: "full_reanalyze"
        )
      end
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
