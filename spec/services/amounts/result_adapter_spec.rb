require 'rails_helper'

RSpec.describe Amounts::ResultAdapter do
  def candidate(**attributes)
    Amounts::Candidate.new(
      candidate_id: 'spec/rejected',
      basis: 'items_as_tax_included',
      subtotal: 1_000,
      tax: 100,
      purchase_total: 1_100,
      score_breakdown: {},
      **attributes
    )
  end

  def adapt(selected_candidate:, candidates: [ selected_candidate ])
    described_class.new(
      base_result: {
        context: :analysis,
        computed: {},
        resolved: {},
        inconsistencies: []
      },
      selected_candidate: selected_candidate,
      candidates: candidates
    ).call
  end

  it 'all rejected candidateでもhard reject由来のreview契約を残す' do
    rejected = candidate(hard_reject_reasons: [ :tax_detail_mismatch ])

    result = adapt(selected_candidate: rejected)

    aggregate_failures do
      expect(result[:needs_review]).to be(true)
      expect(result[:review_reasons]).to include('tax_detail_mismatch')
      expect(result.dig(:amount_engine, :selected_candidate, :hard_reject_reasons)).to include(:tax_detail_mismatch)
    end
  end

  it '通常のaccepted candidateは自動完了可能として扱う' do
    accepted = candidate

    result = adapt(selected_candidate: accepted)

    aggregate_failures do
      expect(result[:needs_review]).to be(false)
      expect(result[:safe_to_auto_complete]).to be(true)
      expect(result[:selected_candidate_status]).to eq('accepted')
      expect(result.dig(:amount_engine, :selected_candidate_status)).to eq('accepted')
      expect(result.dig(:amount_engine, :no_safe_candidate)).to be(false)
    end
  end

  it 'all rejected candidateでは自動完了不可であることを明示する' do
    rejected = candidate(hard_reject_reasons: [ :tax_detail_mismatch ])

    result = adapt(selected_candidate: rejected)

    aggregate_failures do
      expect(result[:needs_review]).to be(true)
      expect(result[:safe_to_auto_complete]).to be(false)
      expect(result[:selected_candidate_status]).to eq('rejected')
      expect(result.dig(:amount_engine, :no_safe_candidate)).to be(true)
      expect(result.dig(:amount_engine, :selected_candidate_status)).to eq('rejected')
    end
  end
end
