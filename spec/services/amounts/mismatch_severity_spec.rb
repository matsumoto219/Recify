require 'rails_helper'

RSpec.describe Amounts::MismatchSeverity do
  describe '.severity' do
    it 'classifies blocking mismatches' do
      aggregate_failures do
        expect(described_class.severity(:total_mismatch)).to eq(:blocking)
        expect(described_class.severity(:item_total_mismatch)).to eq(:blocking)
        expect(described_class.severity(:tax_amount_mismatch)).to eq(:blocking)
        expect(described_class.severity(:tax_detail_mismatch)).to eq(:blocking)
        expect(described_class.severity(:adjustment_uncertain)).to eq(:blocking)
        expect(described_class.severity(:insufficient_data)).to eq(:blocking)
      end
    end

    it 'classifies warning mismatches' do
      aggregate_failures do
        expect(described_class.severity(:ocr_total_mismatch)).to eq(:warning)
        expect(described_class.severity(:tax_detail_rate_mismatch)).to eq(:warning)
        expect(described_class.severity(:tax_detail_incomplete)).to eq(:warning)
        expect(described_class.severity(:tax_detail_partial)).to eq(:warning)
        expect(described_class.severity(:zero_amount_item_incomplete)).to eq(:warning)
        expect(described_class.severity(:discount_data_incomplete)).to eq(:warning)
        expect(described_class.severity(:price_tax_inclusion_uncertain)).to eq(:warning)
        expect(described_class.severity(:competing_exact_basis_candidate)).to eq(:warning)
        expect(described_class.severity(:mixed_basis_search_truncated)).to eq(:warning)
        expect(described_class.severity(:item_tax_rate_group_uncertain)).to eq(:warning)
        expect(described_class.severity(:adjustment_tax_rate_missing)).to eq(:warning)
      end
    end

    it 'treats unknown mismatches as blocking' do
      expect(described_class.severity(:unexpected_mismatch)).to eq(:blocking)
    end
  end

  describe '.needs_review?' do
    it 'returns false for warning-only mismatches' do
      expect(described_class.needs_review?([ :ocr_total_mismatch, :tax_detail_rate_mismatch, :item_tax_rate_group_uncertain ])).to be(false)
    end

    it 'returns true when a blocking mismatch exists' do
      expect(described_class.needs_review?([ :ocr_total_mismatch, :tax_detail_mismatch ])).to be(true)
    end
  end
end
