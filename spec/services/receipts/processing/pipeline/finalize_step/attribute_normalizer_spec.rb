require 'rails_helper'

RSpec.describe Receipts::Processing::Pipeline::FinalizeStep::AttributeNormalizer do
  describe '.items' do
    it 'normalizes receipt item attributes without changing names or the input' do
      item = {
        'raw_text' => ' OCR Raw ',
        'suggested_name' => '提案名',
        'confirmed_name' => '確定名',
        'category' => 'food',
        'price' => '1200',
        'quantity' => '2.5',
        'quantity_unit_code' => 'kg',
        'product_code' => 'P001',
        'tax_rate' => '8%',
        'original_line_total' => '3000',
        'line_total' => '2800',
        'discount_amount' => '200',
        'discount_rate' => '10%',
        'needs_review' => false,
        'review_reasons' => [ ' item_name_uncertain ', '', 'item_name_uncertain' ],
        'position_index' => 7,
        'confidence' => '0.75'
      }
      original = item.deep_dup

      result = described_class.items([ item ]).first

      expect(result).to eq(
        raw_text: ' OCR Raw ',
        suggested_name: '提案名',
        confirmed_name: '確定名',
        category: 'food',
        price: BigDecimal('1200'),
        quantity: BigDecimal('2.5'),
        quantity_unit_code: 'kilogram',
        product_code: 'P001',
        tax_rate: BigDecimal('0.08'),
        original_line_total: BigDecimal('3000'),
        line_total: BigDecimal('2800'),
        discount_amount: BigDecimal('200'),
        discount_rate: BigDecimal('0.1'),
        needs_review: false,
        review_reasons: [ 'item_name_uncertain' ],
        position_index: 7,
        confidence: BigDecimal('0.75')
      )
      expect(item).to eq(original)
    end

    it 'rejects an item with any negative amount but keeps a zero-yen item' do
      result = described_class.items(
        [
          { raw_text: 'negative', line_total: -1 },
          { raw_text: 'zero', price: 0, line_total: 0 }
        ]
      )

      expect(result).to contain_exactly(include(raw_text: 'zero', price: 0, line_total: 0))
    end

    it 'defaults blank, zero, and negative quantities to one' do
      result = described_class.items(
        [
          { raw_text: 'blank', quantity: '' },
          { raw_text: 'zero', quantity: 0 },
          { raw_text: 'negative', quantity: -2 }
        ]
      )

      expect(result.map { |item| item[:quantity] }).to all(eq(BigDecimal('1')))
    end
  end

  describe '.adjustments' do
    it 'keeps only positive amounts and normalizes enum fallbacks and text' do
      result = described_class.adjustments(
        [
          {
            kind: 'unknown',
            label: '  割引  ',
            amount: 100,
            sign: 'unknown',
            tax_rate: 8,
            source: 'unknown',
            source_text: '  evidence  ',
            source_line_index: 3,
            confidence: '0.9',
            needs_review: true,
            review_reasons: [ ' adjustment_uncertain ', 'adjustment_uncertain' ]
          },
          { kind: 'coupon', amount: 0 },
          { kind: 'coupon', amount: -1 }
        ]
      )

      expect(result).to contain_exactly(
        kind: 'other',
        label: '割引',
        amount: BigDecimal('100'),
        sign: 'discount',
        tax_rate: BigDecimal('0.08'),
        source: 'ai',
        source_text: 'evidence',
        source_line_index: 3,
        confidence: BigDecimal('0.9'),
        needs_review: true,
        review_reasons: [ 'adjustment_uncertain' ],
        position_index: 1
      )
    end
  end

  describe 'scalar normalization' do
    it 'normalizes percent and whole-number tax rates' do
      aggregate_failures do
        expect(described_class.tax_rate('8%')).to eq(BigDecimal('0.08'))
        expect(described_class.tax_rate(8)).to eq(BigDecimal('0.08'))
        expect(described_class.tax_rate('invalid')).to be_nil
      end
    end

    it 'rejects negative calculated amounts without rejecting zero' do
      aggregate_failures do
        expect(described_class.safe_calculated_amount(-1)).to be_nil
        expect(described_class.safe_calculated_amount(0)).to eq(BigDecimal('0'))
        expect(described_class.safe_calculated_amount('invalid')).to be_nil
      end
    end

    it 'normalizes confidence and review reason values' do
      aggregate_failures do
        expect(described_class.confidence('0.5')).to eq(BigDecimal('0.5'))
        expect(described_class.confidence('invalid')).to be_nil
        expect(described_class.review_reasons([ ' one ', '', nil, 'one', :two ])).to eq(%w[one two])
      end
    end
  end
end
