require 'rails_helper'

RSpec.describe ReceiptProcessingErrorMapper do
  describe '.map' do
    context 'OCR系エラー' do
      it 'ocr_unreadableはimage_errorになる' do
        result = described_class.map('ocr_unreadable')

        expect(result).to include(
          error_code: 'ocr_unreadable',
          error_category: 'image_error'
        )
      end

      it 'ocr_timeoutはocr_errorになる' do
        result = described_class.map('ocr_timeout')

        expect(result[:error_category]).to eq('ocr_error')
      end
    end

    context 'AI系エラー' do
      it 'ai_timeoutはai_errorになる' do
        result = described_class.map('ai_timeout')

        expect(result[:error_category]).to eq('ai_error')
      end

      it 'analysis_missing_keysはai_errorになる' do
        result = described_class.map('analysis_missing_keys')

        expect(result[:error_category]).to eq('ai_error')
      end
    end

    context '外部サービス系エラー' do
      it 'external_service_unavailableはsystem_errorになる' do
        result = described_class.map('external_service_unavailable')

        expect(result[:error_category]).to eq('system_error')
      end
    end

    context '異常系' do
      it '未知のエラーはsystem_errorになる' do
        result = described_class.map('unknown_error')

        expect(result[:error_category]).to eq('system_error')
      end

      it 'nilはunexpected_errorになる' do
        result = described_class.map(nil)

        expect(result[:error_code]).to eq('unexpected_error')
        expect(result[:error_category]).to eq('system_error')
      end

      it 'symbolでも動く' do
        result = described_class.map(:ocr_timeout)

        expect(result[:error_code]).to eq('ocr_timeout')
      end
    end
  end
end
