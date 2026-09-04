require "rails_helper"
require Rails.root.join("spec/support/ocr/structured_items_gross_fixture")

RSpec.describe Receipts::Processing::Contracts::ReferencePricingStructuredItemsGrossEvidenceSet do
  include StructuredItemsGrossFixture

  def parsed_result(item_specs: default_structured_items_gross_item_specs, total_amount: nil)
    response = build_structured_items_gross_response(item_specs:, total_amount:)

    Ocr::ResponseParser.new(response:, provider: :fixture).call
  end

  def snapshot_for(result = parsed_result)
    Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(result)
  end

  it "複数Itemのgross集合をversioned checksum付きcontractとして1回だけ保存する" do
    snapshot = snapshot_for
    evidence_set = snapshot.dig("adoption_proposals", "reference_pricing_structured_items_gross")
    restored = described_class.from_snapshot(evidence_set, ocr_snapshot: snapshot)

    aggregate_failures do
      expect(evidence_set).to include(
        "schema_version" => "reference_pricing_structured_items_gross_evidence_set_v1",
        "creation_stage" => "ocr_validation",
        "kind" => "structured_items_receipt_inner_tax_summary",
        "source_provider" => "azure_structured",
        "provider_model_id" => "prebuilt-receipt",
        "provider_api_version" => "2024-11-30",
        "string_index_type" => "textElements",
        "integrity_checksum" => match(/\A[0-9a-f]{64}\z/)
      )
      expect(evidence_set.fetch("candidate_members")).to eq([
        { "candidate_id" => "azure_items_0_reference_pricing", "item_index" => 0 },
        { "candidate_id" => "azure_items_1_reference_pricing", "item_index" => 1 }
      ])
      expect(evidence_set.fetch("item_totals").pluck("amount")).to eq([ 600, 600 ])
      expect(evidence_set.dig("summary_total", "amount")).to eq(1_200)
      expect(restored).to eq(evidence_set)
      expect(JSON.generate(evidence_set).bytesize).to be <= described_class::MAX_SERIALIZED_BYTES
      expect(snapshot.to_json.scan(described_class::SCHEMA_VERSION).size).to eq(1)
      expect(evidence_set.to_json).not_to match(/匿名量売品|内税|raw|content|polygon|private/)
    end
  end

  it "non-reference Itemをaggregateへ含めるがcandidate memberにはしない" do
    item_specs = default_structured_items_gross_item_specs + [
      {
        description: "匿名固定額品",
        price_text: "50円",
        price_amount: 50,
        quantity_text: "1個",
        quantity_amount: 1,
        quantity_unit: "個",
        total_text: "50円",
        total_amount: 50
      }
    ]
    evidence_set = snapshot_for(
      parsed_result(item_specs:, total_amount: 1_250)
    ).dig("adoption_proposals", "reference_pricing_structured_items_gross")

    aggregate_failures do
      expect(evidence_set.fetch("item_totals").pluck("amount")).to eq([ 600, 600, 50 ])
      expect(evidence_set.fetch("candidate_members").pluck("item_index")).to eq([ 0, 1 ])
    end
  end

  it "unknown version・checksum不一致・partial member・oversized payloadを集合全体で拒否する" do
    snapshot = snapshot_for
    evidence_set = snapshot.dig("adoption_proposals", "reference_pricing_structured_items_gross")
    mutations = [
      evidence_set.merge("schema_version" => "reference_pricing_structured_items_gross_evidence_set_v2"),
      evidence_set.merge("integrity_checksum" => "0" * 64),
      evidence_set.deep_merge("candidate_members" => [ { "item_index" => 0 } ]),
      evidence_set.deep_merge("item_totals" => [ { "amount" => 601 } ]),
      evidence_set.merge("unknown" => true),
      evidence_set.merge("source_provider" => "x" * (described_class::MAX_SERIALIZED_BYTES + 1))
    ]

    mutations.each do |mutation|
      expect { described_class.from_snapshot(mutation, ocr_snapshot: snapshot) }.not_to raise_error
      expect(described_class.from_snapshot(mutation, ocr_snapshot: snapshot)).to be_nil
    end
  end
end
