require 'rails_helper'

RSpec.describe Receipts::NumericInput do
  describe '.integer' do
    it 'accepts plain, grouped, zero-padded, and full-width integers' do
      aggregate_failures do
        expect(described_class.integer('1000')).to eq(1_000)
        expect(described_class.integer('1,000')).to eq(1_000)
        expect(described_class.integer('001')).to eq(1)
        expect(described_class.integer('１，０００')).to eq(1_000)
        expect(described_class.integer('')).to be_nil
      end
    end

    it 'rejects scientific notation, mixed text, decimals, negatives, and currency symbols' do
      %w[1e2 12abc abc12 1.5 -1 ¥100 ￥１００].each do |value|
        expect { described_class.integer(value) }
          .to raise_error(Receipts::NumericInput::InvalidValue), value
      end
    end
  end

  describe '.decimal' do
    it 'accepts plain and full-width decimal quantities' do
      aggregate_failures do
        expect(described_class.decimal('0.5')).to eq(BigDecimal('0.5'))
        expect(described_class.decimal('０．５')).to eq(BigDecimal('0.5'))
        expect(described_class.decimal('0,300')).to eq(BigDecimal('0.300'))
        expect(described_class.decimal('001')).to eq(BigDecimal('1'))
        expect(described_class.decimal('')).to be_nil
      end
    end

    it 'rejects malformed and negative quantities' do
      %w[1e2 1.2.3 12abc -0.5].each do |value|
        expect { described_class.decimal(value) }
          .to raise_error(Receipts::NumericInput::InvalidValue), value
      end
    end
  end

  describe '.percentage' do
    it 'converts a valid percentage into a decimal rate' do
      aggregate_failures do
        expect(described_class.percentage('10.5')).to eq(BigDecimal('0.105'))
        expect(described_class.percentage('０')).to eq(BigDecimal('0'))
        expect(described_class.percentage('')).to be_nil
      end
    end

    it 'rejects invalid percentages instead of treating them as zero or nil' do
      %w[abc 10percent 1e2 -1 ¥10].each do |value|
        expect { described_class.percentage(value) }
          .to raise_error(Receipts::NumericInput::InvalidValue), value
      end
    end
  end
end
