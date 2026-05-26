require 'rails_helper'

RSpec.describe Analysis do
  describe '.build_receipt_params' do
    it 'ReceiptBuildParamsServiceへ委譲する' do
      ocr_result = { success: true }
      ai_result = { success: true }
      params = { receipt_attributes: { store_name: 'Recify Mart' } }

      allow(Analysis::ReceiptBuildParamsService).to receive(:call).and_return(params)

      expect(described_class.build_receipt_params(ocr_result: ocr_result, ai_result: ai_result)).to eq(params)
      expect(Analysis::ReceiptBuildParamsService).to have_received(:call).with(
        ocr_result: ocr_result,
        ai_result: ai_result
      )
    end
  end

  describe '.processing_error_mapping' do
    it 'ReceiptProcessingErrorMapperへ委譲する' do
      expect(described_class.processing_error_mapping('ocr_api_error')).to eq(
        error_code: 'ocr_api_error',
        error_category: 'ocr_error'
      )
    end
  end

  describe '.processing_error_category' do
    it '表示カテゴリをsymbolで返す' do
      expect(described_class.processing_error_category('image_missing')).to eq(:image_error)
    end
  end

  describe '.detect_category' do
    it 'ReceiptFallbackPatternsのカテゴリ推定を返す' do
      expect(described_class.detect_category('バナナ 1袋')).to eq('food')
    end
  end
end
