require "rails_helper"
require Rails.root.join("spec/support/ocr/structured_items_gross_fixture")

RSpec.describe Ocr::ResponseParser::ReferencePricingStructuredItemsGrossPolicy do
  include StructuredItemsGrossFixture

  def inputs
    response = build_structured_items_gross_response
    analyze_result = response.fetch("analyzeResult")
    items = analyze_result.dig("documents", 0, "fields", "Items", "valueArray")
    candidates = Ocr::ResponseParser::ReferencePricingCandidateExtractor.call(
      items:,
      profile: ReceiptAnalysisProfiles.fetch("JPN"),
      content: analyze_result.fetch("content"),
      string_index_type: analyze_result.fetch("stringIndexType"),
      projection: ->(**attributes) { ReceiptAmountService.reference_item_extension_projection(**attributes) }
    )
    evidence = Ocr::ResponseParser::ReferencePricingStructuredItemsGrossEvidenceExtractor.call(
      analyze_result:,
      profile: ReceiptAnalysisProfiles.fetch("JPN"),
      receipt_total: 1_200
    )
    { candidates:, evidence: }
  end

  def evaluate(candidates: inputs.fetch(:candidates), evidence: inputs.fetch(:evidence), **overrides)
    described_class.call(
      candidates:,
      item_count: 2,
      retained_item_indexes: [ 0, 1 ],
      summary_gross_evidence: evidence,
      adjustment_count: 0,
      discount_count: 0,
      item_line_total_limit: ReceiptAmountService.receipt_item_line_total_max,
      **overrides
    )
  end

  it "複数candidateの唯一の不足がtax inclusionなら集合でgrossへ昇格できる" do
    result = evaluate

    expect(result).to have_attributes(
      eligible: true,
      reason: "eligible",
      reference_price_tax_inclusion: "gross",
      evidence_kind: "structured_items_receipt_inner_tax_summary",
      candidate_ids: %w[azure_items_0_reference_pricing azure_items_1_reference_pricing]
    )
  end

  it "scope・競合・candidate identityの不整合を拒否する" do
    values = inputs
    duplicated = values.fetch(:candidates).map(&:deep_dup)
    duplicated.last[:candidate_id] = duplicated.first[:candidate_id]

    aggregate_failures do
      expect(evaluate(item_count: 1)).not_to be_eligible
      expect(evaluate(retained_item_indexes: [ 0 ])).not_to be_eligible
      expect(evaluate(adjustment_count: 1)).not_to be_eligible
      expect(evaluate(discount_count: 1)).not_to be_eligible
      expect(evaluate(candidates: duplicated, evidence: values.fetch(:evidence))).not_to be_eligible
      expect(evaluate(candidates: values.fetch(:candidates).first(1), evidence: values.fetch(:evidence))).not_to be_eligible
    end
  end

  it "reference以外のItemをaggregate totalに含めつつmemberにしない" do
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
    response = build_structured_items_gross_response(item_specs:, total_amount: 1_250)
    analyze_result = response.fetch("analyzeResult")
    candidates = Ocr::ResponseParser::ReferencePricingCandidateExtractor.call(
      items: analyze_result.dig("documents", 0, "fields", "Items", "valueArray"),
      profile: ReceiptAnalysisProfiles.fetch("JPN"),
      content: analyze_result.fetch("content"),
      string_index_type: analyze_result.fetch("stringIndexType"),
      projection: ->(**attributes) { ReceiptAmountService.reference_item_extension_projection(**attributes) }
    )
    evidence = Ocr::ResponseParser::ReferencePricingStructuredItemsGrossEvidenceExtractor.call(
      analyze_result:,
      profile: ReceiptAnalysisProfiles.fetch("JPN"),
      receipt_total: 1_250
    )

    result = described_class.call(
      candidates:,
      item_count: 3,
      retained_item_indexes: [ 0, 1, 2 ],
      summary_gross_evidence: evidence,
      adjustment_count: 0,
      discount_count: 0,
      item_line_total_limit: ReceiptAmountService.receipt_item_line_total_max
    )

    aggregate_failures do
      expect(result).to be_eligible
      expect(result.candidate_members).to eq([
        { candidate_id: "azure_items_0_reference_pricing", item_index: 0 },
        { candidate_id: "azure_items_1_reference_pricing", item_index: 1 }
      ])
    end
  end

  it "formula・printed item total・aggregate totalのどの不一致も拒否する" do
    values = inputs
    formula_mismatch = values.fetch(:candidates).map(&:deep_dup)
    formula_mismatch.first[:reference_price][:amount] = "241"
    printed_mismatch = values.fetch(:candidates).map(&:deep_dup)
    printed_mismatch.first[:printed_line_total][:amount] = "601"
    aggregate_mismatch = values.fetch(:evidence).to_h.deep_dup
    aggregate_mismatch[:summary_total][:amount] = 1_201

    aggregate_failures do
      expect(evaluate(candidates: formula_mismatch, evidence: values.fetch(:evidence))).not_to be_eligible
      expect(evaluate(candidates: printed_mismatch, evidence: values.fetch(:evidence))).not_to be_eligible
      expect(evaluate(evidence: aggregate_mismatch)).not_to be_eligible
    end
  end
end
