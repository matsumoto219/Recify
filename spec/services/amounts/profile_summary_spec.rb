require 'rails_helper'

RSpec.describe Amounts::ProfileSummary do
  def candidate(**attributes)
    Amounts::Candidate.new(
      **{
        candidate_id: 'items_as_tax_included/floor/per_item',
        basis: 'items_as_tax_included',
        subtotal: 100,
        tax: 8,
        purchase_total: 108,
        rounding_mode: :floor,
        rounding_scope: :per_item,
        score: 0,
        score_breakdown: {},
        warnings: [],
        source: :amount_engine
      }.merge(attributes)
    )
  end

  it 'returns empty profile result outside analysis context' do
    result = described_class.call(
      selected_candidate: candidate,
      candidates: [ candidate ],
      context: :manual
    )

    aggregate_failures do
      expect(result.profile).to be_nil
      expect(result.score).to be_nil
      expect(result.candidates).to eq([])
      expect(result.warnings).to eq([])
    end
  end

  it 'builds a calculation_profile compatible summary from native candidates' do
    selected = candidate(
      candidate_id: 'external_tax_from_receipt/floor',
      basis: 'external_tax_from_receipt',
      subtotal: 1_000,
      tax: 100,
      purchase_total: 1_100,
      score: 0,
      score_breakdown: {
        receipt_total_delta: 0,
        receipt_subtotal_delta: 0,
        receipt_tax_delta: 0
      },
      calculation_profile: {
        receipt_tax_basis: :tax_added_to_subtotal,
        item_amount_basis: :line_total_as_recorded,
        tax_detail_amount_basis: :net
      }
    )
    alternative = candidate(
      candidate_id: 'items_as_tax_included/round/per_item',
      rounding_mode: :round,
      score: 100,
      score_breakdown: {
        receipt_total_delta: 100,
        receipt_subtotal_delta: 30,
        receipt_tax_delta: 60
      },
      warnings: [ :price_tax_inclusion_uncertain ]
    )

    result = described_class.call(
      selected_candidate: selected,
      candidates: [ selected, alternative ],
      context: :analysis
    )

    aggregate_failures do
      expect(result.profile).to eq(
        tax_rounding_mode: :floor,
        discount_rounding_mode: :round,
        receipt_tax_basis: :tax_added_to_subtotal,
        item_amount_basis: :line_total_as_recorded
      )
      expect(result.score).to eq(0)
      expect(result.candidates).to include(
        hash_including(
          profile: hash_including(
            tax_rounding_mode: :round,
            discount_rounding_mode: :round,
            receipt_tax_basis: :total_includes_tax,
            item_amount_basis: :line_total_as_recorded
          ),
          score: 230,
          deltas: {
            total: 1,
            subtotal: 1,
            tax: 1,
            tax_details: 0,
            item_line_total: 0,
            discount: 0,
            basis_relation: 0
          }
        )
      )
      expect(result.warnings).to eq([])
    end
  end
end
