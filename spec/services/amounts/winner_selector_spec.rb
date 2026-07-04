require 'rails_helper'

RSpec.describe Amounts::WinnerSelector do
  def candidate(id:, basis:, score:, warnings: [], score_breakdown: exact_score_breakdown, rejected: false)
    Amounts::Candidate.new(
      candidate_id: id,
      basis: basis,
      subtotal: 1_000,
      tax: 100,
      purchase_total: 1_100,
      final_payment_total: 1_100,
      score: score,
      score_breakdown: score_breakdown,
      warnings: warnings,
      hard_reject_reasons: rejected ? [ :tax_detail_mismatch ] : []
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
end
