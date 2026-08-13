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

  describe '.grouped_decimal' do
    it 'treats a valid single thousands separator as grouping for decimal amounts' do
      aggregate_failures do
        expect(described_class.grouped_decimal('1,000')).to eq(BigDecimal('1000'))
        expect(described_class.grouped_decimal('1,000.5')).to eq(BigDecimal('1000.5'))
        expect(described_class.grouped_decimal('１，０００．５')).to eq(BigDecimal('1000.5'))
      end
    end

    it 'does not reinterpret a broken thousands group as a decimal comma' do
      expect { described_class.grouped_decimal('1,00') }
        .to raise_error(Receipts::NumericInput::InvalidValue)
    end
  end

  describe '.percentage' do
    it 'converts a valid percentage into a decimal rate' do
      aggregate_failures do
        expect(described_class.percentage('0.5')).to eq(BigDecimal('0.005'))
        expect(described_class.percentage('1')).to eq(BigDecimal('0.01'))
        expect(described_class.percentage('1.1')).to eq(BigDecimal('0.011'))
        expect(described_class.percentage('10.5')).to eq(BigDecimal('0.105'))
        expect(described_class.percentage('100')).to eq(BigDecimal('1'))
        expect(described_class.percentage('０')).to eq(BigDecimal('0'))
        expect(described_class.percentage('')).to be_nil
      end
    end

    it 'rejects invalid percentages instead of treating them as zero or nil' do
      %w[abc 10percent 1e2 -1 100.1 ¥10].each do |value|
        expect { described_class.percentage(value) }
          .to raise_error(Receipts::NumericInput::InvalidValue), value
      end
    end
  end

  describe '.tax_percentage' do
    it 'accepts only percentages that fit the persisted tax-rate scale exactly' do
      aggregate_failures do
        expect(described_class.tax_percentage('10.55')).to eq(BigDecimal('0.1055'))
        expect(described_class.tax_percentage('１０．５５０')).to eq(BigDecimal('0.1055'))
        expect(described_class.tax_percentage('0.01')).to eq(BigDecimal('0.0001'))
        expect(described_class.tax_percentage('')).to be_nil
      end
    end

    it 'rejects percentages that the database would round' do
      %w[10.555 0.001 10.5550000000000000000000001].each do |value|
        expect { described_class.tax_percentage(value) }
          .to raise_error(Receipts::NumericInput::InvalidValue), value
      end
    end
  end

  describe '.discount_percentage' do
    it 'accepts only percentages that fit the persisted discount-rate scale exactly' do
      aggregate_failures do
        expect(described_class.discount_percentage('10.5')).to eq(BigDecimal('0.105'))
        expect(described_class.discount_percentage('１０．５０')).to eq(BigDecimal('0.105'))
        expect(described_class.discount_percentage('0.1')).to eq(BigDecimal('0.001'))
        expect(described_class.discount_percentage('')).to be_nil
      end
    end

    it 'rejects percentages that the database would round' do
      %w[10.55 0.01 10.5000000000000000000000001].each do |value|
        expect { described_class.discount_percentage(value) }
          .to raise_error(Receipts::NumericInput::InvalidValue), value
      end
    end
  end

  describe '.receipt_tax_rate' do
    it 'preserves the accepted ratio-or-percentage shape while validating persisted scale' do
      aggregate_failures do
        expect(described_class.receipt_tax_rate('0.1055')).to eq(BigDecimal('0.1055'))
        expect(described_class.receipt_tax_rate('10.55')).to eq(BigDecimal('10.55'))
        expect(described_class.receipt_tax_rate('')).to be_nil
      end
    end

    it 'rejects ratio and percentage forms that the database would round' do
      %w[0.10555 10.555].each do |value|
        expect { described_class.receipt_tax_rate(value) }
          .to raise_error(Receipts::NumericInput::InvalidValue), value
      end
    end
  end

  it 'matches the rate scales of every manual persistence target' do
    aggregate_failures do
      expect(described_class::TAX_RATE_MAX_SCALE).to eq(Receipt.columns_hash.fetch('tax_rate').scale)
      expect(described_class::TAX_RATE_MAX_SCALE).to eq(ReceiptItem.columns_hash.fetch('tax_rate').scale)
      expect(described_class::TAX_RATE_MAX_SCALE).to eq(ReceiptAdjustment.columns_hash.fetch('tax_rate').scale)
      expect(described_class::TAX_RATE_MAX_SCALE).to eq(ReceiptTaxDetail.columns_hash.fetch('rate').scale)
      expect(described_class::DISCOUNT_RATE_MAX_SCALE).to eq(ReceiptItem.columns_hash.fetch('discount_rate').scale)
    end
  end
end
