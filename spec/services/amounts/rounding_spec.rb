require 'rails_helper'

RSpec.describe Amounts::Rounding do
  describe '.normalize_rounding_mode' do
    it 'keeps allowed symbol values' do
      aggregate_failures do
        expect(described_class.normalize_rounding_mode(:floor)).to eq(:floor)
        expect(described_class.normalize_rounding_mode(:ceil)).to eq(:ceil)
        expect(described_class.normalize_rounding_mode(:round)).to eq(:round)
      end
    end

    it 'accepts string values' do
      aggregate_failures do
        expect(described_class.normalize_rounding_mode('floor')).to eq(:floor)
        expect(described_class.normalize_rounding_mode('ceil')).to eq(:ceil)
        expect(described_class.normalize_rounding_mode('round')).to eq(:round)
      end
    end

    it 'falls back invalid values to floor' do
      aggregate_failures do
        expect(described_class.normalize_rounding_mode(nil)).to eq(:floor)
        expect(described_class.normalize_rounding_mode(:unexpected)).to eq(:floor)
        expect(described_class.normalize_rounding_mode('unexpected')).to eq(:floor)
      end
    end
  end

  describe '.apply_rounding' do
    it 'applies floor rounding' do
      expect(described_class.apply_rounding(BigDecimal('9.8'), :floor)).to eq(9)
    end

    it 'applies ceil rounding' do
      expect(described_class.apply_rounding(BigDecimal('9.1'), :ceil)).to eq(10)
    end

    it 'applies round rounding' do
      aggregate_failures do
        expect(described_class.apply_rounding(BigDecimal('9.4'), :round)).to eq(9)
        expect(described_class.apply_rounding(BigDecimal('9.5'), :round)).to eq(10)
      end
    end
  end
end
