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

  it 'family symbolから対応するfamilyを実行する' do
    generator = Class.new do
      private

      def detected_tax_details
        []
      end
    end.new

    expect(described_class.build(:printed_tax_details, generator)).to eq([])
  end
end
