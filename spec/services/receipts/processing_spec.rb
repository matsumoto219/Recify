require "rails_helper"

RSpec.describe Receipts::Processing do
  describe "public result contracts" do
    it "Resultの省略keywordとsuccess判定をimmutable objectで維持する" do
      result = described_class::Result.new(
        ocr_result: { success: true },
        next_step: :ai
      )

      aggregate_failures do
        expect(result).to be_frozen
        expect(result).to be_success
        expect(result.to_h).to eq(
          ocr_result: { success: true },
          ai_result: nil,
          finalize_decision: nil,
          next_step: :ai,
          skip_reason: nil
        )
        expect { result.next_step = :finalize }.to raise_error(NoMethodError)
      end
    end

    it "AI resultをOCRより優先する既存success判定を維持する" do
      result = described_class::Result.new(
        ocr_result: { success: true },
        ai_result: { success: false }
      )

      expect(result).not_to be_success
    end

    it "StartResultのcreated helperをimmutable objectで維持する" do
      run = instance_double(ReceiptAnalysisRun)
      result = described_class::StartResult.new(run: run, created: true)

      aggregate_failures do
        expect(result).to be_frozen
        expect(result).to be_created
        expect(result.to_h).to eq(run: run, created: true)
        expect { result.created = false }.to raise_error(NoMethodError)
      end
    end
  end

  describe "pipeline facade" do
    it "OCR stageをprivate Pipelineへ委譲する" do
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
    it "run作成をprivate Runsへ委譲する" do
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
