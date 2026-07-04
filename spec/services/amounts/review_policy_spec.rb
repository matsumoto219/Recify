require 'rails_helper'

RSpec.describe Amounts::ReviewPolicy do
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

  def apply_policy(candidate, existing_inconsistencies: [])
    described_class.new(candidate: candidate, existing_inconsistencies: existing_inconsistencies).call
  end

  it 'blocking inconsistencyをreview reasonにする' do
    result = apply_policy(candidate(warnings: [ :payment_amount_mismatch ]))

    aggregate_failures do
      expect(result[:inconsistencies]).to include(:payment_amount_mismatch)
      expect(result[:review_reasons]).to include('payment_amount_mismatch')
      expect(result[:needs_review]).to be(true)
    end
  end

  it '通常warningのみならdiagnosticとして残しreview reasonにしない' do
    result = apply_policy(candidate(warnings: [ :calculation_profile_uncertain ]))

    aggregate_failures do
      expect(result[:inconsistencies]).to include(:calculation_profile_uncertain)
      expect(result[:review_reasons]).to be_empty
      expect(result[:needs_review]).to be(false)
    end
  end

  it '単一税率のadjustment_tax_rate_missingはwarning-onlyに留める' do
    result = apply_policy(
      candidate(
        warnings: [ :adjustment_tax_rate_missing ],
        tax_rate_groups: [
          { rate: BigDecimal('0.10'), gross: 1_100, net: 1_000, tax: 100 }
        ],
        evidence: [
          { source: 'receipt_adjustment', effect: :purchase_adjustment, amount: 100, tax_rate: BigDecimal('0') }
        ]
      )
    )

    aggregate_failures do
      expect(result[:inconsistencies]).to include(:adjustment_tax_rate_missing)
      expect(result[:review_reasons]).to be_empty
      expect(result[:needs_review]).to be(false)
    end
  end

  it '複数税率のpurchase adjustment税率欠落は税配賦不確実としてreview reasonにする' do
    result = apply_policy(
      candidate(
        warnings: [ :adjustment_tax_rate_missing ],
        tax_rate_groups: [
          { rate: BigDecimal('0.08'), gross: 540, net: 500, tax: 40 },
          { rate: BigDecimal('0.10'), gross: 1_100, net: 1_000, tax: 100 }
        ],
        evidence: [
          { source: 'receipt_adjustment', effect: :purchase_adjustment, amount: 100, tax_rate: BigDecimal('0') }
        ]
      )
    )

    aggregate_failures do
      expect(result[:inconsistencies]).to include(:adjustment_tax_rate_missing)
      expect(result[:review_reasons]).to eq([ 'purchase_adjustment_tax_allocation_uncertain' ])
      expect(result[:needs_review]).to be(true)
    end
  end

  it '印字tax detailsありのpurchase adjustment税率欠落は税配賦不確実としてreview reasonにする' do
    result = apply_policy(
      candidate(
        warnings: [ :adjustment_tax_rate_missing ],
        tax_rate_groups: [
          { rate: BigDecimal('0.10'), gross: 1_100, net: 1_000, tax: 100 }
        ],
        evidence: [
          { source: 'receipt_tax_detail', rate: BigDecimal('0.10'), basis: :gross, amount: 100, net_amount: 1_000 },
          { source: 'receipt_adjustment', effect: :purchase_adjustment, amount: 100, tax_rate: BigDecimal('0') }
        ]
      )
    )

    aggregate_failures do
      expect(result[:review_reasons]).to eq([ 'purchase_adjustment_tax_allocation_uncertain' ])
      expect(result[:needs_review]).to be(true)
    end
  end

  it 'mixed basis候補のpurchase adjustment税率欠落は税配賦不確実としてreview reasonにする' do
    result = apply_policy(
      candidate(
        basis: 'mixed_by_tax_rate_group',
        warnings: [ :adjustment_tax_rate_missing ],
        tax_rate_groups: [
          { rate: BigDecimal('0.10'), gross: 1_100, net: 1_000, tax: 100 }
        ],
        evidence: [
          { source: 'receipt_adjustment', effect: :purchase_adjustment, amount: 100, tax_rate: BigDecimal('0') }
        ]
      )
    )

    aggregate_failures do
      expect(result[:review_reasons]).to eq([ 'purchase_adjustment_tax_allocation_uncertain' ])
      expect(result[:needs_review]).to be(true)
    end
  end

  it 'price_tax_inclusion_uncertainは非blockingの確認対象としてreview reasonにする' do
    result = apply_policy(candidate(warnings: [ :price_tax_inclusion_uncertain ]))

    aggregate_failures do
      expect(Amounts::MismatchSeverity.severity(:price_tax_inclusion_uncertain)).to eq(:warning)
      expect(result[:review_reasons]).to eq([ 'price_tax_inclusion_uncertain' ])
      expect(result[:needs_review]).to be(true)
    end
  end

  it '印字税抜tax detailsが候補金額と一致する場合はprice_tax_inclusion_uncertainをwarning-onlyに留める' do
    result = apply_policy(
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

    aggregate_failures do
      expect(result[:inconsistencies]).to include(:price_tax_inclusion_uncertain)
      expect(result[:review_reasons]).to be_empty
      expect(result[:needs_review]).to be(false)
    end
  end

  it '印字税抜tax detailsが一致してもcompeting exact basis候補がある場合はprice_tax_inclusion_uncertainをreview reasonに残す' do
    result = apply_policy(
      candidate(
        basis: 'printed_tax_details_net',
        warnings: [ :price_tax_inclusion_uncertain ],
        tax_details: [
          { rate: BigDecimal('0.10'), net_amount: 1_000, amount: 100 }
        ],
        score_breakdown: {
          receipt_total_delta: 0
        }
      ),
      existing_inconsistencies: [ :competing_exact_basis_candidate ]
    )

    aggregate_failures do
      expect(result[:inconsistencies]).to include(:price_tax_inclusion_uncertain, :competing_exact_basis_candidate)
      expect(result[:review_reasons]).to include('price_tax_inclusion_uncertain')
      expect(result[:review_reasons]).to include('competing_exact_basis_candidate')
      expect(result[:needs_review]).to be(true)
    end
  end

  it 'incomplete_tax_details_receipt_taxのtax_detail_incompleteはreview reasonに昇格する' do
    result = apply_policy(
      candidate(
        basis: 'incomplete_tax_details_receipt_tax',
        warnings: [ :tax_detail_incomplete ]
      )
    )

    aggregate_failures do
      expect(Amounts::MismatchSeverity.severity(:tax_detail_incomplete)).to eq(:warning)
      expect(result[:review_reasons]).to eq([ 'tax_detail_incomplete' ])
      expect(result[:needs_review]).to be(true)
    end
  end

  it 'unknown inconsistencyはblockingとして扱う' do
    result = apply_policy(candidate(warnings: [ :unexpected_amount_boundary ]))

    aggregate_failures do
      expect(Amounts::MismatchSeverity.severity(:unexpected_amount_boundary)).to eq(:blocking)
      expect(result[:review_reasons]).to eq([ 'unexpected_amount_boundary' ])
      expect(result[:needs_review]).to be(true)
    end
  end
end
