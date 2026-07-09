require "rails_helper"

RSpec.describe Analysis::TaxAllocationResolver do
  let(:profile) { ReceiptAnalysisProfiles.default }

  def resolve_ownership(lines:, items:, adjustments:, tax_details: [])
    Analysis::ReceiptFactOwnershipResolver.call(
      items: items,
      adjustments: adjustments,
      payments: [],
      tax_details: tax_details,
      review_reasons: [],
      evidence_index: Analysis::SourceEvidenceIndex.call(
        lines: lines,
        money_pattern: profile.analysis_adjustment_amount_candidate_pattern,
        profile: profile
      ),
      profile: profile
    )
  end

  def allocate(ownership_result, items: ownership_result.items, adjustments: ownership_result.adjustments, tax_details: ownership_result.tax_details)
    described_class.call(
      ownership_result: ownership_result,
      items: items,
      adjustments: adjustments,
      tax_details: tax_details
    )
  end

  it "明示tax rateを維持してexplicit sourceにする" do
    ownership_result = resolve_ownership(
      lines: [ "クーポン -100円 10%" ],
      items: [ { raw_text: "商品A", line_total: 1_100, tax_rate: 0.1 } ],
      adjustments: [
        { kind: "coupon", sign: "discount", amount: 100, tax_rate: 0.1, source_text: "クーポン -100円 10%", source_line_index: 0 }
      ]
    )

    result = allocate(ownership_result)
    fact = result.facts.find { |candidate| candidate.origin == :adjustment }

    aggregate_failures do
      expect(result.adjustments).to contain_exactly(include(tax_rate: BigDecimal("0.1")))
      expect(fact).to have_attributes(tax_rate: BigDecimal("0.1"), tax_rate_source: :explicit)
    end
  end

  it "fee-owned itemをadjustmentへ一本化した場合はitem tax rateを継承する" do
    ownership_result = resolve_ownership(
      lines: [ "袋代 10円" ],
      items: [ { raw_text: "袋代", line_total: 10, tax_rate: 0.1 } ],
      adjustments: [
        { kind: "bag_fee", sign: "surcharge", amount: 10, source_text: "袋代 10円", source_line_index: 0 }
      ]
    )

    result = allocate(ownership_result)
    fact = result.facts.find { |candidate| candidate.origin == :adjustment }

    aggregate_failures do
      expect(result.items).to eq([])
      expect(result.adjustments).to contain_exactly(include(tax_rate: BigDecimal("0.1")))
      expect(fact).to have_attributes(tax_rate: BigDecimal("0.1"), tax_rate_source: :inherited)
    end
  end

  it "一意に一致するprinted tax detailからtax rateを補う" do
    ownership_result = resolve_ownership(
      lines: [ "クーポン -100円", "10%対象 100円" ],
      items: [],
      adjustments: [
        { kind: "coupon", sign: "discount", amount: 100, source_text: "クーポン -100円", source_line_index: 0 }
      ],
      tax_details: [ { description: "10%対象", rate: 0.1, net_amount: 91, amount: 9 } ]
    )

    result = allocate(ownership_result)
    fact = result.facts.find { |candidate| candidate.origin == :adjustment }

    aggregate_failures do
      expect(result.adjustments).to contain_exactly(include(tax_rate: BigDecimal("0.1")))
      expect(fact).to have_attributes(tax_rate_source: :matched)
    end
  end

  it "課税対象が安全な単一税率ならsingle_rateとして補う" do
    ownership_result = resolve_ownership(
      lines: [ "商品A 1,100円", "クーポン -100円" ],
      items: [ { raw_text: "商品A", line_total: 1_100, tax_rate: 0.1 } ],
      adjustments: [
        { kind: "coupon", sign: "discount", amount: 100, source_text: "クーポン -100円", source_line_index: 1 }
      ]
    )

    result = allocate(ownership_result)
    fact = result.facts.find { |candidate| candidate.origin == :adjustment }

    aggregate_failures do
      expect(result.adjustments).to contain_exactly(include(tax_rate: BigDecimal("0.1")))
      expect(fact).to have_attributes(tax_rate_source: :single_rate)
      expect(result.review_reasons).not_to include("purchase_adjustment_tax_allocation_uncertain")
    end
  end

  it "payment adjustmentはtax allocation対象外にする" do
    ownership_result = resolve_ownership(
      lines: [ "ポイント利用 -100円" ],
      items: [ { raw_text: "商品A", line_total: 1_100, tax_rate: 0.1 } ],
      adjustments: [
        { kind: "point_usage", sign: "discount", amount: 100, tax_rate: 0.1, source_text: "ポイント利用 -100円", source_line_index: 0 }
      ]
    )

    result = allocate(ownership_result)
    fact = result.facts.find { |candidate| candidate.origin == :adjustment }

    aggregate_failures do
      expect(result.adjustments).to contain_exactly(include(kind: "point_usage", amount: 100))
      expect(result.adjustments.first).not_to have_key(:tax_rate)
      expect(fact).to have_attributes(tax_rate: nil, tax_rate_source: :not_applicable)
    end
  end

  it "複数税率または課税・非課税混在で配賦不能ならunknown reviewにする" do
    multiple_rates = resolve_ownership(
      lines: [ "商品A 1,080円", "商品B 1,100円", "クーポン -100円" ],
      items: [
        { raw_text: "商品A", line_total: 1_080, tax_rate: 0.08 },
        { raw_text: "商品B", line_total: 1_100, tax_rate: 0.1 }
      ],
      adjustments: [
        { kind: "coupon", sign: "discount", amount: 100, source_text: "クーポン -100円", source_line_index: 2 }
      ]
    )
    taxable_and_non_taxable = resolve_ownership(
      lines: [ "商品A 1,100円", "非課税商品 500円", "クーポン -100円" ],
      items: [
        { raw_text: "商品A", line_total: 1_100, tax_rate: 0.1 },
        { raw_text: "非課税商品", line_total: 500, tax_rate: 0 }
      ],
      adjustments: [
        { kind: "coupon", sign: "discount", amount: 100, source_text: "クーポン -100円", source_line_index: 2 }
      ]
    )

    [ multiple_rates, taxable_and_non_taxable ].each do |ownership_result|
      result = allocate(ownership_result)
      fact = result.facts.find { |candidate| candidate.origin == :adjustment }

      aggregate_failures do
        expect(result.review_reasons).to include("purchase_adjustment_tax_allocation_uncertain")
        expect(result.adjustments.first).to include(
          needs_review: true,
          review_reasons: include("purchase_adjustment_tax_allocation_uncertain")
        )
        expect(fact).to have_attributes(tax_rate: nil, tax_rate_source: :unknown)
      end
    end
  end
end
