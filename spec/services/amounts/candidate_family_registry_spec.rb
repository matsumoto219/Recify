require 'rails_helper'

RSpec.describe Amounts::CandidateFamilyRegistry do
  it 'candidate familyの評価順序を固定する' do
    expect(described_class.call).to eq(
      %i[
        receipt_input
        incomplete_tax_details_receipt_tax
        item_amounts
        printed_tax_details
        mixed_tax_basis
      ]
    )
  end

  it 'family symbolから対応するbuilderへ委譲する' do
    generator = Class.new do
      private

      def item_candidates
        :item_candidates
      end
    end.new

    expect(described_class.build(:item_amounts, generator)).to eq(:item_candidates)
  end
end
