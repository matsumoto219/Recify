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

  it 'candidate calculation_profileをbasis文字列より優先してcomputed basisに使う' do
    profiled = candidate(
      basis: 'items_as_tax_included',
      calculation_profile: {
        receipt_tax_basis: :tax_added_to_subtotal,
        item_amount_basis: :line_total_as_net,
        tax_detail_amount_basis: :net
      }
    )

    result = adapt(selected_candidate: profiled)

    expect(result[:computed]).to include(
      receipt_tax_basis: :tax_added_to_subtotal,
      item_amount_basis: :line_total_as_net,
      tax_detail_amount_basis: :net
    )
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

  it '実際のselected candidateの丸め条件をprofile rankingとは分離して返す' do
    selected = candidate(
      rounding_mode: :ceil,
      rounding_scope: :per_item,
      calculation_profile: { discount_rounding_mode: :floor }
    )

    result = described_class.new(
      base_result: { context: :analysis, rounding_mode: { tax: :floor, discount: :round } },
      selected_candidate: selected,
      candidates: [ selected ],
      calculation_profile_result: { profile: { tax_rounding_mode: :round, discount_rounding_mode: :round } }
    ).call

    aggregate_failures do
      expect(result[:applied_calculation_settings]).to eq(
        'schema_version' => 1,
        'tax_rounding_mode' => { 'value' => 'ceil', 'origin' => 'analysis' },
        'discount_rounding_mode' => { 'value' => 'floor', 'origin' => 'analysis' },
        'tax_rounding_scope' => { 'value' => 'per_item', 'origin' => 'analysis' }
      )
      expect(result[:rounding_mode]).to eq(tax: :floor, discount: :round)
    end
  end

  it 'rejected candidateを適用済みの条件として返さない' do
    result = adapt(selected_candidate: candidate(hard_reject_reasons: [ :tax_detail_mismatch ]))

    expect(result).not_to have_key(:applied_calculation_settings)
  end

  it 'manual結果へanalysis由来の条件を追加しない' do
    selected = candidate

    result = described_class.new(
      base_result: { context: :manual },
      selected_candidate: selected,
      candidates: [ selected ]
    ).call

    expect(result).not_to have_key(:applied_calculation_settings)
  end

  it 'candidateにない割引丸め条件を既定値で補わない' do
    result = adapt(selected_candidate: candidate)

    expect(result[:applied_calculation_settings]).not_to have_key('discount_rounding_mode')
  end

  it 'ItemAmountsの購入調整basisを明細の個別basisと分離して記録する' do
    selected = candidate(
      basis: 'items_as_tax_excluded',
      calculation_profile: { item_amount_basis: :mixed_by_tax_rate_group, discount_rounding_mode: :round },
      evidence: [ { source: 'receipt_adjustment', effect: :purchase_adjustment } ]
    )

    result = adapt(selected_candidate: selected)

    expect(result[:applied_calculation_settings]).to include(
      'purchase_adjustment_tax_inclusion' => { 'value' => 'net', 'origin' => 'analysis' }
    )
  end

  it '印字税内訳候補の調整basisをReceipt全体の税区分から推測しない' do
    selected = candidate(
      basis: 'printed_tax_details_net',
      evidence: [ { source: 'receipt_adjustment', effect: :purchase_adjustment } ]
    )

    result = adapt(selected_candidate: selected)

    expect(result[:applied_calculation_settings]).not_to have_key('purchase_adjustment_tax_inclusion')
  end
end
