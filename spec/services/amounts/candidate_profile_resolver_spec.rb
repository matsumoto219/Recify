require 'rails_helper'

RSpec.describe Amounts::CandidateProfileResolver do
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

  it 'candidate calculation_profileをbasis fallbackより優先する' do
    resolver = described_class.new(
      candidate(
        basis: 'items_as_tax_included',
        calculation_profile: {
          receipt_tax_basis: :tax_added_to_subtotal,
          item_amount_basis: :line_total_as_net,
          tax_detail_amount_basis: :net
        }
      )
    )

    aggregate_failures do
      expect(resolver.receipt_tax_basis).to eq(:tax_added_to_subtotal)
      expect(resolver.item_amount_basis).to eq(:line_total_as_net)
      expect(resolver.tax_detail_amount_basis).to eq(:net)
    end
  end

  it 'profileがない場合は既存basis fallbackを返す' do
    resolver = described_class.new(candidate(basis: 'external_tax_from_receipt'))

    aggregate_failures do
      expect(resolver.receipt_tax_basis).to eq(:tax_added_to_subtotal)
      expect(resolver.item_amount_basis).to eq(:line_total_as_net)
      expect(resolver.tax_detail_amount_basis).to eq(:net)
    end
  end
end
