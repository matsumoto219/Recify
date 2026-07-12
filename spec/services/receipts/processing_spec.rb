require "rails_helper"

RSpec.describe Receipts::Processing do
  describe "public contracts" do
    it "legacy workflowのErrorとResult contractを同一objectで公開する" do
      aggregate_failures do
        expect(described_class::AnalysisError).to equal(ReceiptAnalysisPipeline::AnalysisError)
        expect(described_class::EnqueueError).to equal(ReceiptAnalysisRuns::EnqueueError)
        expect(described_class::Error).to equal(ReceiptAnalysisRuns::Error)
        expect(described_class::InvalidTransition).to equal(ReceiptAnalysisRuns::InvalidTransition)
        expect(described_class::Result).to equal(ReceiptAnalysisPipeline::Result)
        expect(described_class::StartResult).to equal(ReceiptAnalysisRuns::StartResult)
        expect(described_class::TerminalRunError).to equal(ReceiptAnalysisRuns::TerminalRunError)
      end
    end
  end

  describe "pipeline facade" do
    it "OCR stageをlegacy Pipelineへ委譲する" do
      run = instance_double(ReceiptAnalysisRun)
      allow(ReceiptAnalysisPipeline).to receive(:run_ocr).with(run).and_return(:result)

      expect(described_class.run_ocr(run)).to eq(:result)
    end
  end

  describe "run lifecycle facade" do
    it "run作成をlegacy Runsへ委譲する" do
      arguments = { receipt: instance_double(Receipt), source: "upload" }
      allow(ReceiptAnalysisRuns).to receive(:start).with(**arguments).and_return(:result)

      expect(described_class.start(**arguments)).to eq(:result)
    end
  end

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
