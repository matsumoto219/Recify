require 'rails_helper'

RSpec.describe ReviewReasons do
  describe '.display_category_for' do
    it 'classifies content reasons without treating the category as provenance' do
      aggregate_failures do
        expect(described_class.display_category_for('item_name_uncertain')).to eq(:content)
        expect(described_class.display_category_for(:item_category_uncertain)).to eq(:content)
        expect(described_class.display_category_for('item_tax_rate_uncertain')).to eq(:content)
        expect(described_class.display_category_for('store_name_missing')).to eq(:content)
        expect(described_class.display_category_for('purchased_at_missing')).to eq(:content)
        expect(described_class.display_category_for('payment_method_missing')).to eq(:content)
      end
    end

    it 'classifies ocr reasons' do
      aggregate_failures do
        expect(described_class.display_category_for('ocr_unreadable')).to eq(:ocr)
        expect(described_class.display_category_for(:ocr_low_confidence)).to eq(:ocr)
        expect(described_class.display_category_for('multiple_receipts_suspected')).to eq(:ocr)
      end
    end

    it 'classifies amount reasons' do
      aggregate_failures do
        expect(described_class.display_category_for('total_mismatch')).to eq(:amount)
        expect(described_class.display_category_for(:tax_detail_mismatch)).to eq(:amount)
        expect(described_class.display_category_for('tax_detail_incomplete')).to eq(:amount)
        expect(described_class.display_category_for(:tax_detail_partial)).to eq(:amount)
        expect(described_class.display_category_for('zero_amount_item_incomplete')).to eq(:amount)
        expect(described_class.display_category_for('price_tax_inclusion_uncertain')).to eq(:amount)
        expect(described_class.display_category_for('competing_exact_basis_candidate')).to eq(:amount)
        expect(described_class.display_category_for('mixed_basis_search_truncated')).to eq(:amount)
        expect(described_class.display_category_for('calculation_profile_uncertain')).to eq(:amount)
        expect(described_class.display_category_for('item_tax_rate_group_uncertain')).to eq(:amount)
        expect(described_class.display_category_for('item_pricing_mode_uncertain')).to eq(:amount)
        expect(described_class.display_category_for('purchase_adjustment_tax_allocation_uncertain')).to eq(:amount)
      end
    end

    it 'classifies system reasons' do
      aggregate_failures do
        expect(described_class.display_category_for('ai_api_error')).to eq(:system)
        expect(described_class.display_category_for('ai_auth_error')).to eq(:system)
        expect(described_class.display_category_for('ai_invalid_request')).to eq(:system)
        expect(described_class.display_category_for(:ai_timeout)).to eq(:system)
        expect(described_class.display_category_for('ai_unavailable')).to eq(:system)
        expect(described_class.display_category_for('ai_quota_exceeded')).to eq(:system)
        expect(described_class.display_category_for('ai_rate_limited')).to eq(:system)
        expect(described_class.display_category_for('unexpected_error')).to eq(:system)
        expect(described_class.display_category_for('analysis_missing_keys')).to eq(:system)
      end
    end

    it 'falls back unknown reasons to unknown' do
      aggregate_failures do
        expect(described_class.display_category_for('custom_reason')).to eq(:unknown)
        expect(described_class.display_category_for(nil)).to eq(:unknown)
      end
    end
  end

  describe '.group_by_display_category' do
    it 'groups normalized reasons by their display meaning' do
      result = described_class.group_by_display_category([
        :purchased_at_missing,
        'ocr_low_confidence',
        'tax_detail_mismatch',
        'unexpected_error',
        'custom_reason'
      ])

      aggregate_failures do
        expect(result[:content]).to eq([ 'purchased_at_missing' ])
        expect(result[:ocr]).to eq([ 'ocr_low_confidence' ])
        expect(result[:amount]).to eq([ 'tax_detail_mismatch' ])
        expect(result[:system]).to eq([ 'unexpected_error' ])
        expect(result[:unknown]).to eq([ 'custom_reason' ])
      end
    end

    it 'returns all display category keys even when empty' do
      result = described_class.group_by_display_category([])

      expect(result).to eq(
        content: [],
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
        'unexpected_error',
        'custom_reason'
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
        'multiple_receipts_suspected',
        'item_tax_rate_uncertain',
        'item_name_uncertain',
        'item_pricing_mode_uncertain',
        'tax_detail_mismatch',
        'analysis_missing_keys',
        'custom_reason'
      ])

      expect(result).to eq([
        'multiple_receipts_suspected',
        'item_name_uncertain',
        'item_pricing_mode_uncertain',
        'tax_detail_mismatch'
      ])
    end
  end

  describe '.normalize_ai_output_reasons' do
    it 'keeps only review reasons allowed in AI responses' do
      result = described_class.normalize_ai_output_reasons([
        'item_name_uncertain',
        :adjustment_uncertain,
        'ocr_low_confidence',
        'payment_amount_mismatch',
        'item_pricing_mode_uncertain',
        'ai_timeout',
        'custom_reason',
        nil,
        ' '
      ])

      expect(result).to eq([
        'item_name_uncertain',
        'adjustment_uncertain',
        'ocr_low_confidence'
      ])
    end
  end

  describe 'definitions' do
    it 'has no duplicate reason codes in formal allowlists' do
      aggregate_failures do
        expect(described_class::USER_FACING_REASONS).to eq(described_class::USER_FACING_REASONS.uniq)
        expect(described_class::ALL_REASONS).to eq(described_class::ALL_REASONS.uniq)
        expect(described_class::AI_OUTPUT_REASONS).to eq(described_class::AI_OUTPUT_REASONS.uniq)
      end
    end

    it 'keeps AI output reasons inside the formal reason list' do
      expect(described_class::AI_OUTPUT_REASONS - described_class::ALL_REASONS).to eq([])
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

  describe 'locale' do
    it '複数レシート疑いの表示文言を持つ' do
      expect(I18n.t('enums.receipt_item.review_reason.multiple_receipts_suspected')).to eq(
        '1枚の画像に複数のレシートが含まれている可能性があります'
      )
    end
  end
end
