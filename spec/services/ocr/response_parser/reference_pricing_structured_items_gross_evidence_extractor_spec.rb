require "rails_helper"
require Rails.root.join("spec/support/ocr/structured_items_gross_fixture")

RSpec.describe Ocr::ResponseParser::ReferencePricingStructuredItemsGrossEvidenceExtractor do
  include StructuredItemsGrossFixture

  def extract(response = build_structured_items_gross_response, receipt_total: 1_200)
    described_class.call(
      analyze_result: response.fetch("analyzeResult"),
      profile: ReceiptAnalysisProfiles.fetch("JPN"),
      receipt_total:
    )
  end

  def extract_with_profile(response, profile:, receipt_total: 1_200)
    described_class.call(
      analyze_result: response.fetch("analyzeResult"),
      profile:,
      receipt_total:
    )
  end

  it "複数Itemのexact totalと内税TaxDetailsをbounded aggregate evidenceへ変換する" do
    response = build_structured_items_gross_response(
      tax_descriptions: [ "内税", "内消費税等" ],
      tax_amounts: [ 44, 56 ]
    )
    evidence = extract(response)

    aggregate_failures do
      expect(evidence.kind).to eq("structured_items_receipt_inner_tax_summary")
      expect(evidence.item_parents.pluck(:item_index)).to eq([ 0, 1 ])
      expect(evidence.item_totals.pluck(:amount)).to eq([ 600, 600 ])
      expect(evidence.tax_detail_parents.pluck(:tax_detail_index)).to eq([ 0, 1 ])
      expect(evidence.tax_descriptions.pluck(:tax_detail_index)).to eq([ 0, 1 ])
      expect(evidence.tax_amounts.pluck(:amount)).to eq([ 44, 56 ])
      expect(evidence.summary_total[:amount]).to eq(1_200)
      expect(evidence.to_h.to_json).not_to match(/匿名量売品|内消費税|raw|content|polygon/)
    end
  end

  it "複数のnative reference候補だけをgross validへ昇格する" do
    result = Ocr::ResponseParser.new(
      response: build_structured_items_gross_response,
      provider: :fixture
    ).call
    references = result.dig(:candidates, :reference_pricing_candidates)

    aggregate_failures do
      expect(references.size).to eq(2)
      expect(references.pluck(:item_index)).to eq([ 0, 1 ])
      expect(references.pluck(:validation_state)).to eq(%w[valid valid])
      expect(references.pluck(:reference_price_tax_inclusion)).to eq(%w[gross gross])
      expect(references.map { |candidate| candidate.dig(:tax_inclusion_evidence, :kind) }).to eq(
        %w[
          structured_items_receipt_inner_tax_summary_member
          structured_items_receipt_inner_tax_summary_member
        ]
      )
      expect(result.dig(:candidates, :reference_pricing_structured_items_gross_evidence, :candidate_members)).to eq(
        [
          { candidate_id: "azure_items_0_reference_pricing", item_index: 0 },
          { candidate_id: "azure_items_1_reference_pricing", item_index: 1 }
        ]
      )
    end
  end

  it "TaxDetailsの内税DescriptionがexactならAmount欠損を許容する" do
    evidence = extract(
      build_structured_items_gross_response(
        tax_descriptions: [ "内税", "内消費税等" ],
        tax_amounts: [ 100, nil ]
      )
    )

    aggregate_failures do
      expect(evidence.tax_descriptions.pluck(:tax_detail_index)).to eq([ 0, 1 ])
      expect(evidence.tax_amounts.pluck(:tax_detail_index)).to eq([ 0 ])
    end
  end

  it "括弧で囲まれたTaxDetailsの末尾記号を税額component境界として許容する" do
    evidence = extract(
      build_structured_items_gross_response(tax_parenthesized: true)
    )

    aggregate_failures do
      expect(evidence).to be_present
      expect(evidence.tax_amounts.pluck(:amount)).to eq([ 100 ])
    end
  end

  it "内税語彙は注入profileだけから取得する" do
    profile = ReceiptAnalysisProfiles.fetch("JPN")
    allow(profile).to receive(
      :ocr_reference_pricing_single_structured_item_inner_tax_description_pattern
    ).and_return(/\Ainclusive\z/)
    matching = build_structured_items_gross_response(tax_descriptions: [ "inclusive" ])
    japanese = build_structured_items_gross_response

    aggregate_failures do
      expect(extract_with_profile(matching, profile:)).to be_present
      expect(extract_with_profile(japanese, profile:)).to be_nil
    end
  end

  it "non-reference Itemのexact totalもreceipt aggregateへ含める" do
    items = default_structured_items_gross_item_specs + [
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
    response = build_structured_items_gross_response(item_specs: items, total_amount: 1_250)
    evidence = extract(response, receipt_total: 1_250)
    parsed = Ocr::ResponseParser.new(response:, provider: :fixture).call

    aggregate_failures do
      expect(evidence.item_totals.pluck(:amount)).to eq([ 600, 600, 50 ])
      expect(parsed.dig(:candidates, :reference_pricing_candidates).pluck(:validation_state)).to eq(
        %w[valid valid]
      )
    end
  end

  it "Item total集合とsummary Totalの不一致を拒否する" do
    response = build_structured_items_gross_response(total_amount: 1_201)

    aggregate_failures do
      expect(extract(response, receipt_total: 1_201)).to be_nil
      expect(
        Ocr::ResponseParser.new(response:, provider: :fixture).call.dig(
          :candidates,
          :reference_pricing_candidates
        ).pluck(:validation_state)
      ).to eq(%w[ambiguous ambiguous])
    end
  end

  it "外税・欠損total・重複parent・unsupported indexをfail-closedにする" do
    external_tax = build_structured_items_gross_response(tax_descriptions: [ "外税" ])
    missing_total = build_structured_items_gross_response
    missing_total.dig(
      "analyzeResult", "documents", 0, "fields", "Items", "valueArray", 1, "valueObject"
    ).delete("TotalPrice")
    overlapping = build_structured_items_gross_response
    first_span = overlapping.dig(
      "analyzeResult", "documents", 0, "fields", "Items", "valueArray", 0, "spans"
    ).deep_dup
    overlapping.dig(
      "analyzeResult", "documents", 0, "fields", "Items", "valueArray", 1
    )["spans"] = first_span
    unsupported = build_structured_items_gross_response
    unsupported.dig("analyzeResult")["stringIndexType"] = "utf8Byte"
    malformed_tax_amount = build_structured_items_gross_response
    malformed_tax_amount.dig(
      "analyzeResult", "documents", 0, "fields", "TaxDetails", "valueArray", 0,
      "valueObject", "Amount", "valueCurrency"
    )["amount"] = 101.5

    aggregate_failures do
      expect(extract(external_tax)).to be_nil
      expect(extract(missing_total)).to be_nil
      expect(extract(overlapping)).to be_nil
      expect(extract(unsupported)).to be_nil
      expect(extract(malformed_tax_amount)).to be_nil
    end
  end

  it "単一Itemは既存single policyへ委譲し20件を上限とする" do
    single = build_structured_items_gross_response(
      item_specs: [ default_structured_items_gross_item_specs.first ],
      total_amount: 600
    )
    oversized_items = Array.new(21) do |index|
      default_structured_items_gross_item_specs.fetch(index % 2).merge(
        description: "匿名品#{index}"
      )
    end
    oversized = build_structured_items_gross_response(item_specs: oversized_items)

    aggregate_failures do
      expect(extract(single, receipt_total: 600)).to be_nil
      expect(extract(oversized, receipt_total: 12_600)).to be_nil
    end
  end
end
