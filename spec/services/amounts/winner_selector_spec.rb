require 'rails_helper'

RSpec.describe Amounts::WinnerSelector do
  def candidate(id:, basis:, score:, warnings: [], score_breakdown: exact_score_breakdown, rejected: false, tax_rate_groups: [], evidence: [], subtotal: 1_000, tax: 100, purchase_total: 1_100)
    Amounts::Candidate.new(
      candidate_id: id,
      basis: basis,
      subtotal: subtotal,
      tax: tax,
      purchase_total: purchase_total,
      final_payment_total: purchase_total,
      score: score,
      score_breakdown: score_breakdown,
      warnings: warnings,
      hard_reject_reasons: rejected ? [ :tax_detail_mismatch ] : [],
      tax_rate_groups: tax_rate_groups,
      evidence: evidence
    )
  end

  def exact_score_breakdown
    {
      receipt_total_delta: 0,
      receipt_subtotal_delta: 0,
      receipt_tax_delta: 0,
      payment_delta: 0,
      receipt_input_item_delta: 0,
      warning_penalty: 10,
      basis_penalty: -1
    }
  end

  it 'printed tax details net候補と別basisのexact候補が競合する場合はselected candidateへwarningを付ける' do
    selected = candidate(
      id: 'printed_tax_details_net/floor',
      basis: 'printed_tax_details_net',
      score: 9,
      warnings: [ :price_tax_inclusion_uncertain ]
    )
    competing = candidate(
      id: 'items_as_tax_included/floor/per_receipt',
      basis: 'items_as_tax_included',
      score: 12
    )

    result = described_class.new([ selected, competing ]).call

    aggregate_failures do
      expect(result.candidate_id).to eq('printed_tax_details_net/floor')
      expect(result.warnings).to include(:price_tax_inclusion_uncertain, :competing_exact_basis_candidate)
    end
  end

  it '同scoreの場合はcandidate_id順ではなく明示したbasis優先順でwinnerを選ぶ' do
    printed = candidate(
      id: 'aaa_printed_tax_details_net/floor',
      basis: 'printed_tax_details_net',
      score: 10
    )
    external = candidate(
      id: 'zzz_external_tax_from_receipt/floor',
      basis: 'external_tax_from_receipt',
      score: 10
    )

    result = described_class.new([ printed, external ]).call

    expect(result.candidate_id).to eq('zzz_external_tax_from_receipt/floor')
  end

  it '同scoreの場合はcandidate_id順よりwarningの少ない候補を優先する' do
    warning_candidate = candidate(
      id: 'aaa_warning_candidate',
      basis: 'items_as_tax_included',
      score: 10,
      warnings: [ :price_tax_inclusion_uncertain ]
    )
    clean_candidate = candidate(
      id: 'zzz_clean_candidate',
      basis: 'items_as_tax_included',
      score: 10
    )

    result = described_class.new([ warning_candidate, clean_candidate ]).call

    expect(result.candidate_id).to eq('zzz_clean_candidate')
  end

  it '同scoreの場合は保存済み入力候補をcandidate_id順より優先する' do
    external = candidate(
      id: 'aaa_external_tax_from_receipt/floor',
      basis: 'external_tax_from_receipt',
      score: 10
    )
    receipt_input = candidate(
      id: 'zzz_receipt_input',
      basis: 'receipt_input_preserved',
      score: 10
    )

    result = described_class.new([ external, receipt_input ]).call

    expect(result.candidate_id).to eq('zzz_receipt_input')
  end

  it '別basisのexact候補がなければcompeting warningを付けない' do
    selected = candidate(
      id: 'printed_tax_details_net/floor',
      basis: 'printed_tax_details_net',
      score: 9,
      warnings: [ :price_tax_inclusion_uncertain ]
    )
    same_basis = candidate(
      id: 'printed_tax_details_net/round',
      basis: 'printed_tax_details_net',
      score: 109,
      warnings: [ :price_tax_inclusion_uncertain ]
    )

    result = described_class.new([ selected, same_basis ]).call

    expect(result.warnings).not_to include(:competing_exact_basis_candidate)
  end

  it '別basis候補がexactでもwarning付きならcompeting warningを付けない' do
    selected = candidate(
      id: 'printed_tax_details_net/floor',
      basis: 'printed_tax_details_net',
      score: 9,
      warnings: [ :price_tax_inclusion_uncertain ]
    )
    competing = candidate(
      id: 'printed_tax_details_raw_sum/floor',
      basis: 'printed_tax_details_raw_sum',
      score: 35,
      warnings: [ :tax_detail_mismatch, :price_tax_inclusion_uncertain ]
    )

    result = described_class.new([ selected, competing ]).call

    expect(result.warnings).not_to include(:competing_exact_basis_candidate)
  end

  it '税額0円の印字税詳細が強い根拠を持つ場合はcompeting warningを付けない' do
    selected = candidate(
      id: 'printed_tax_details_net/floor',
      basis: 'printed_tax_details_net',
      score: 9,
      warnings: [ :price_tax_inclusion_uncertain ],
      subtotal: 742,
      tax: 59,
      purchase_total: 801,
      tax_rate_groups: [
        { rate: BigDecimal('0.08'), gross: 798, net: 739, tax: 59 },
        { rate: BigDecimal('0.10'), gross: 3, net: 3, tax: 0 }
      ],
      evidence: [
        { source: 'receipt_tax_detail', rate: BigDecimal('0.08'), basis: :net, target_gross_amount: 798, target_tax_amount: 59 },
        { source: 'receipt_tax_detail', rate: BigDecimal('0.10'), basis: :net, target_gross_amount: 3, target_tax_amount: 0 }
      ]
    )
    competing = candidate(
      id: 'items_as_tax_included/floor/per_receipt',
      basis: 'items_as_tax_included',
      score: 12
    )

    result = described_class.new([ selected, competing ]).call

    expect(result.warnings).not_to include(:competing_exact_basis_candidate)
  end

  it 'mixed basis探索打ち切りwarningをselected candidateへ引き継ぐ' do
    selected = candidate(
      id: 'printed_tax_details_net/floor',
      basis: 'printed_tax_details_net',
      score: 9,
      warnings: [ :price_tax_inclusion_uncertain ]
    )
    truncated = candidate(
      id: 'mixed_by_tax_rate_group/floor',
      basis: 'mixed_by_tax_rate_group',
      score: 1_000,
      warnings: [ :price_tax_inclusion_uncertain, :mixed_basis_search_truncated ],
      rejected: true
    )

    result = described_class.new([ selected, truncated ]).call

    expect(result.warnings).to include(:mixed_basis_search_truncated)
  end
end
