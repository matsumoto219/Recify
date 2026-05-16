require 'rails_helper'

RSpec.describe Amounts::CalculationProfileResult do
  describe '.wrap' do
    it 'wraps nil input as an empty result' do
      result = described_class.wrap(nil)

      aggregate_failures do
        expect(result.profile).to be_nil
        expect(result.score).to be_nil
        expect(result.candidates).to eq([])
        expect(result.warnings).to eq([])
        expect(result.warning_codes).to eq([])
        expect(result).not_to be_present
        expect(result.to_h).to eq(
          profile: nil,
          score: nil,
          candidates: [],
          warnings: []
        )
      end
    end

    it 'returns an existing result unchanged' do
      result = described_class.new(profile: { receipt_tax_basis: :total_includes_tax })

      expect(described_class.wrap(result)).to be(result)
    end
  end

  describe '#with_applied_profile' do
    it 'returns a new result with applied profile metadata without changing ResultTemplate hash shape' do
      profile = {
        tax_rounding_mode: :floor,
        discount_rounding_mode: :round,
        receipt_tax_basis: :tax_added_to_subtotal,
        item_amount_basis: :line_total_as_recorded
      }
      candidate = { profile: profile, score: 0 }

      result = described_class.new(
        profile: profile,
        score: 0,
        candidates: [ candidate ],
        warnings: [ :price_tax_inclusion_uncertain ]
      )
      applied_result = result.with_applied_profile(profile)

      aggregate_failures do
        expect(applied_result).not_to be(result)
        expect(applied_result.applied_profile).to eq(profile)
        expect(applied_result.profile).to eq(profile)
        expect(applied_result.score).to eq(0)
        expect(applied_result.candidates).to eq([ candidate ])
        expect(applied_result.warnings).to eq([ :price_tax_inclusion_uncertain ])
        expect(applied_result.warning_codes).to eq([ 'PRICE_TAX_INCLUSION_UNCERTAIN' ])
        expect(applied_result).to be_present
        expect(applied_result.to_h).to eq(
          profile: profile,
          score: 0,
          candidates: [ candidate ],
          warnings: [ :price_tax_inclusion_uncertain ]
        )
      end
    end
  end
end
