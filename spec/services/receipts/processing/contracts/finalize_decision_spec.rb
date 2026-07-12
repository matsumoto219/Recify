require "rails_helper"

RSpec.describe Receipts::Processing::Contracts::FinalizeDecision do
  it "schema・strategy・field shapeを固定する" do
    aggregate_failures do
      expect(described_class::SCHEMA_VERSION).to eq("receipt_analysis_run_finalize_decision_v1")
      expect(described_class::STRATEGIES).to eq(%w[fail_receipt ocr_only ai_fallback ai_success])
      expect(described_class.members).to eq(%i[
        finalize_strategy
        error_code
        error_message
        receipt_attributes
        ocr_result
        ai_result
        metadata
      ])
    end
  end

  it "保存済みsnapshotを復元し、raw OCR/AI resultは復元しない" do
    decision = described_class.from_snapshot(
      schema_version: described_class::SCHEMA_VERSION,
      strategy: "fail_receipt",
      error_code: "unsupported_country",
      error_message: "country_region=USA",
      receipt_attributes: { country_region: "USA" },
      metadata: { reason: "unsupported_country" },
      ocr_result: { raw_text: "保存しないOCR全文" },
      ai_result: { messages: [ "保存しないmessages" ] }
    )

    aggregate_failures do
      expect(decision.finalize_strategy).to eq("fail_receipt")
      expect(decision.strategy).to eq("fail_receipt")
      expect(decision.error_code).to eq("unsupported_country")
      expect(decision.error_message).to eq("country_region=USA")
      expect(decision.receipt_attributes).to eq("country_region" => "USA")
      expect(decision.metadata).to eq("reason" => "unsupported_country")
      expect(decision.ocr_result).to be_nil
      expect(decision.ai_result).to be_nil
    end
  end

  it "空・旧schema・未知strategyを拒否する" do
    aggregate_failures do
      expect(described_class.from_snapshot(nil)).to be_nil
      expect(described_class.from_snapshot(schema_version: "old", strategy: "ai_success")).to be_nil
      expect(
        described_class.from_snapshot(
          schema_version: described_class::SCHEMA_VERSION,
          strategy: "unknown"
        )
      ).to be_nil
    end
  end
end
