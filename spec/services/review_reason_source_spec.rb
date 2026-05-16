require 'rails_helper'

RSpec.describe ReviewReasonSource do
  describe '.source_for' do
    it 'classifies ai reasons' do
      aggregate_failures do
        expect(described_class.source_for('item_name_uncertain')).to eq(:ai)
        expect(described_class.source_for(:item_category_uncertain)).to eq(:ai)
        expect(described_class.source_for('item_tax_rate_uncertain')).to eq(:ai)
        expect(described_class.source_for('store_name_missing')).to eq(:ai)
        expect(described_class.source_for('payment_method_uncertain')).to eq(:ai)
      end
    end

    it 'classifies ocr reasons' do
      aggregate_failures do
        expect(described_class.source_for('ocr_unreadable')).to eq(:ocr)
        expect(described_class.source_for(:ocr_low_confidence)).to eq(:ocr)
      end
    end

    it 'classifies amount reasons' do
      aggregate_failures do
        expect(described_class.source_for('total_mismatch')).to eq(:amount)
        expect(described_class.source_for(:tax_detail_mismatch)).to eq(:amount)
        expect(described_class.source_for('tax_detail_incomplete')).to eq(:amount)
        expect(described_class.source_for(:tax_detail_partial)).to eq(:amount)
        expect(described_class.source_for('zero_amount_item_incomplete')).to eq(:amount)
        expect(described_class.source_for('price_tax_inclusion_uncertain')).to eq(:amount)
        expect(described_class.source_for('calculation_profile_uncertain')).to eq(:amount)
        expect(described_class.source_for('item_tax_rate_group_uncertain')).to eq(:amount)
      end
    end

    it 'classifies system reasons' do
      aggregate_failures do
        expect(described_class.source_for('ai_api_error')).to eq(:system)
        expect(described_class.source_for(:ai_timeout)).to eq(:system)
        expect(described_class.source_for('unexpected_error')).to eq(:system)
        expect(described_class.source_for('analysis_missing_keys')).to eq(:system)
      end
    end

    it 'falls back unknown reasons to unknown' do
      aggregate_failures do
        expect(described_class.source_for('custom_reason')).to eq(:unknown)
        expect(described_class.source_for(nil)).to eq(:unknown)
      end
    end
  end

  describe '.group_by_source' do
    it 'groups normalized reasons by source' do
      result = described_class.group_by_source([
        :item_name_uncertain,
        'ocr_low_confidence',
        'tax_detail_mismatch',
        'unexpected_error',
        'custom_reason'
      ])

      aggregate_failures do
        expect(result[:ai]).to eq(['item_name_uncertain'])
        expect(result[:ocr]).to eq(['ocr_low_confidence'])
        expect(result[:amount]).to eq(['tax_detail_mismatch'])
        expect(result[:system]).to eq(['unexpected_error'])
        expect(result[:unknown]).to eq(['custom_reason'])
      end
    end

    it 'returns all source keys even when empty' do
      result = described_class.group_by_source([])

      expect(result).to eq(
        ai: [],
        ocr: [],
        amount: [],
        system: [],
        unknown: []
      )
    end
  end

  describe '.review_reasons_for_user' do
    it 'excludes system reasons and keeps user-facing reasons' do
      result = described_class.review_reasons_for_user([
        'item_name_uncertain',
        'ocr_low_confidence',
        'tax_detail_mismatch',
        'analysis_missing_keys',
        'unexpected_error'
      ])

      expect(result).to eq([
        'item_name_uncertain',
        'ocr_low_confidence',
        'tax_detail_mismatch'
      ])
    end
  end

  describe '.warning_reasons_for_user' do
    it 'keeps user-facing warning reasons only' do
      result = described_class.warning_reasons_for_user([
        'ocr_low_confidence',
        'tax_detail_rate_mismatch',
        'tax_detail_incomplete',
        'tax_detail_partial',
        'zero_amount_item_incomplete',
        'calculation_profile_uncertain',
        'item_tax_rate_group_uncertain',
        'item_tax_rate_uncertain',
        'tax_detail_mismatch',
        'analysis_missing_keys'
      ])

      expect(result).to eq([
        'ocr_low_confidence',
        'tax_detail_rate_mismatch',
        'tax_detail_incomplete',
        'tax_detail_partial',
        'zero_amount_item_incomplete',
        'calculation_profile_uncertain',
        'item_tax_rate_group_uncertain',
        'item_tax_rate_uncertain'
      ])
    end
  end

  describe '.blocking_reasons_for_user' do
    it 'keeps user-facing blocking reasons only' do
      result = described_class.blocking_reasons_for_user([
        'ocr_low_confidence',
        'item_tax_rate_uncertain',
        'item_name_uncertain',
        'tax_detail_mismatch',
        'analysis_missing_keys'
      ])

      expect(result).to eq([
        'item_name_uncertain',
        'tax_detail_mismatch'
      ])
    end
  end

  describe '.internal_processing_reasons' do
    it 'keeps only system reasons' do
      result = described_class.internal_processing_reasons([
        'item_name_uncertain',
        'analysis_missing_keys',
        'unexpected_error'
      ])

      expect(result).to eq([
        'analysis_missing_keys',
        'unexpected_error'
      ])
    end
  end
end
