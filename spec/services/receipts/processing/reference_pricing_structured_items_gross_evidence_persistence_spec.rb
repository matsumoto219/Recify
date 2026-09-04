require "rails_helper"
require Rails.root.join("spec/support/ocr/structured_items_gross_fixture")

RSpec.describe "Reference pricing structured items gross evidence persistence" do
  include StructuredItemsGrossFixture

  def parsed_result
    Ocr::ResponseParser.new(
      response: build_structured_items_gross_response,
      provider: :fixture
    ).call
  end

  def snapshot
    Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(parsed_result)
  end

  it "full setを一度だけ保存しcandidateとoptionはcompact checksum handleで参照する" do
    value = snapshot
    evidence_set = value.dig("adoption_proposals", "reference_pricing_structured_items_gross")
    checksum = evidence_set.fetch("integrity_checksum")
    candidate_handles = value.dig("candidates", "reference_pricing_candidates").map do |candidate|
      candidate.fetch("tax_inclusion_evidence")
    end
    option_handles = value.dig("adoption_proposals", "item_calculation_modes").filter_map do |proposal|
      proposal.fetch("options").find do |option|
        option["pricing_source_kind"] == "reference_quantity_price"
      end&.dig("evidence", "tax_inclusion")
    end

    aggregate_failures do
      expect(candidate_handles).to eq([
        {
          "kind" => "structured_items_receipt_inner_tax_summary_member",
          "policy_contract_version" => "reference_pricing_structured_items_gross_policy_v1",
          "evidence_set_checksum" => checksum,
          "item_index" => 0
        },
        {
          "kind" => "structured_items_receipt_inner_tax_summary_member",
          "policy_contract_version" => "reference_pricing_structured_items_gross_policy_v1",
          "evidence_set_checksum" => checksum,
          "item_index" => 1
        }
      ])
      expect(option_handles).to eq(candidate_handles)
      expect(JSON.generate(value).scan("\"item_parents\"").size).to eq(1)
      expect(option_handles.to_json).not_to match(/item_parents|item_totals|summary_total|raw|content|polygon/)
    end
  end

  it "JSON・retry sanitize・Finalize rehydrateで集合とcompact handleをexactに維持する" do
    initial = snapshot
    copied = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(
      JSON.parse(JSON.generate(initial))
    )
    rehydrated = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(copied)

    aggregate_failures do
      expect(copied.dig("adoption_proposals", "reference_pricing_structured_items_gross")).to eq(
        initial.dig("adoption_proposals", "reference_pricing_structured_items_gross")
      )
      expect(copied.dig("adoption_proposals", "item_calculation_modes")).to eq(
        initial.dig("adoption_proposals", "item_calculation_modes")
      )
      expect(rehydrated.dig(:adoption_proposals, "reference_pricing_structured_items_gross")).to eq(
        initial.dig("adoption_proposals", "reference_pricing_structured_items_gross")
      )
      expect(rehydrated.dig(:adoption_proposals, "item_calculation_modes")).to eq(
        initial.dig("adoption_proposals", "item_calculation_modes")
      )
    end
  end

  it "複数proposalの検証でfull setを1回だけrehydrateしてmemberをindex参照する" do
    initial = snapshot
    proposals = initial.dig("adoption_proposals", "item_calculation_modes")
    contract = Receipts::Processing::Contracts::ReferencePricingStructuredItemsGrossEvidenceSet
    expect(contract).to receive(:from_snapshot).once.and_call_original

    restored = Receipts::Processing::Contracts::ItemCalculationModeProposalSet.from_snapshot(
      proposals,
      ocr_snapshot: initial
    )

    expect(restored).to eq(proposals)
  end

  it "sibling欠損・集合改変・member checksum改変をfail-closedにし通常OCR候補は維持する" do
    initial = snapshot
    missing = initial.deep_dup
    missing.dig("adoption_proposals").delete("reference_pricing_structured_items_gross")
    changed_set = initial.deep_dup
    changed_set.dig(
      "adoption_proposals",
      "reference_pricing_structured_items_gross",
      "item_totals",
      0
    )["amount"] = 601
    changed_handle = initial.deep_dup
    changed_handle.dig(
      "candidates",
      "reference_pricing_candidates",
      0,
      "tax_inclusion_evidence"
    )["evidence_set_checksum"] = "0" * 64

    [ missing, changed_set, changed_handle ].each do |value|
      copied = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(value)
      rehydrated = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(value)

      aggregate_failures do
        expect(copied.dig("adoption_proposals", "item_calculation_modes")).to be_nil
        expect(rehydrated.dig(:adoption_proposals, "item_calculation_modes")).to be_nil
        expect(copied.dig("candidates", "items").size).to eq(2)
        expect(copied.dig("candidates", "reference_pricing_candidates").size).to eq(2)
      end
    end
  end

  it "集合keyのないold snapshotとordinary count proposalを従来どおり復元する" do
    raw = JSON.parse(Rails.root.join("spec/fixtures/ocr/single_tax_receipt.json").read)
    ordinary = Ocr::ResponseParser.new(response: raw, provider: :fixture).call
    initial = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(ordinary)
    copied = Receipts::Processing::Runs::SnapshotBuilder.ocr_result_snapshot(
      JSON.parse(JSON.generate(initial))
    )
    rehydrated = Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator.ocr(copied)

    aggregate_failures do
      expect(initial.dig("adoption_proposals", "reference_pricing_structured_items_gross")).to be_nil
      expect(copied.dig("adoption_proposals", "item_calculation_modes")).to eq(
        initial.dig("adoption_proposals", "item_calculation_modes")
      )
      expect(rehydrated.dig(:adoption_proposals, "item_calculation_modes")).to eq(
        initial.dig("adoption_proposals", "item_calculation_modes")
      )
    end
  end
end
