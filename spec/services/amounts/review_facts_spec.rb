require 'rails_helper'

RSpec.describe Amounts::ReviewFacts do
  def candidate(**attributes)
    Amounts::Candidate.new(
      candidate_id: 'spec/floor',
      basis: 'items_as_tax_included',
      subtotal: 1_000,
      tax: 100,
      purchase_total: 1_100,
      score_breakdown: {},
      **attributes
    )
  end

  it 'purchase adjustmentの税率欠落を構造化して判定する' do
    facts = described_class.new(
      candidate(
        evidence: [
          { source: 'receipt_adjustment', effect: :purchase_adjustment, amount: 100, tax_rate: BigDecimal('0') }
        ]
      )
    )

    expect(facts.tax_rate_missing_purchase_adjustment?).to be(true)
  end

  it '複数税率のpurchase adjustment税配賦不確実を判定する' do
    facts = described_class.new(
      candidate(
        tax_rate_groups: [
          { rate: BigDecimal('0.08'), gross: 540, net: 500, tax: 40 },
          { rate: BigDecimal('0.10'), gross: 1_100, net: 1_000, tax: 100 }
        ]
      )
    )

    expect(facts.purchase_adjustment_tax_allocation_uncertain?).to be(true)
  end

  it '印字税抜tax detailsが一致する単独warningをwarning-onlyとして判定する' do
    facts = described_class.new(
      candidate(
        basis: 'printed_tax_details_net',
        warnings: [ :price_tax_inclusion_uncertain ],
        tax_details: [
          { rate: BigDecimal('0.10'), net_amount: 1_000, amount: 100 }
        ],
        score_breakdown: {
          receipt_total_delta: 0
        }
      )
    )

    expect(facts.tax_detail_net_price_tax_warning_only?(inconsistencies: [ :price_tax_inclusion_uncertain ])).to be(true)
  end

  it 'competing exact basisがある場合はwarning-onlyにしない' do
    facts = described_class.new(
      candidate(
        basis: 'printed_tax_details_net',
        warnings: [ :price_tax_inclusion_uncertain ],
        tax_details: [
          { rate: BigDecimal('0.10'), net_amount: 1_000, amount: 100 }
        ],
        score_breakdown: {
          receipt_total_delta: 0
        }
      )
    )

    expect(
      facts.tax_detail_net_price_tax_warning_only?(
        inconsistencies: [ :price_tax_inclusion_uncertain, :competing_exact_basis_candidate ]
      )
    ).to be(false)
  end
end
