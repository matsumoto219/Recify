require 'rails_helper'

RSpec.describe Analysis::ReceiptProcessingErrorMapper do
  describe '.map' do
    it 'OCRエラーを正しく変換する' do
      result = described_class.map("ocr_timeout")

      expect(result).to eq(
        error_code: "ocr_timeout",
        error_category: "ocr_error"
      )
    end

    it 'AIエラーを正しく変換する' do
      result = described_class.map("ai_timeout")

      expect(result).to eq(
        error_code: "ai_timeout",
        error_category: "ai_error"
      )
    end

    it 'AI primary/fallbackのprovider失敗をAIエラーとして変換する' do
      aggregate_failures do
        expect(described_class.map("ai_primary_failed")).to eq(
          error_code: "ai_primary_failed",
          error_category: "ai_error"
        )
        expect(described_class.map("ai_fallback_failed")).to eq(
          error_code: "ai_fallback_failed",
          error_category: "ai_error"
        )
      end
    end

    it 'AIのnot receipt判定は画像エラーとして変換する' do
      result = described_class.map("ai_not_receipt")

      expect(result).to eq(
        error_code: "ai_not_receipt",
        error_category: "image_error"
      )
    end

    it 'AIのnot receipt判定が不確かな場合も画像エラーとして変換する' do
      result = described_class.map("ai_not_receipt_uncertain")

      expect(result).to eq(
        error_code: "ai_not_receipt_uncertain",
        error_category: "image_error"
      )
    end

    it '画像エラーを正しく変換する' do
      result = described_class.map("image_missing")

      expect(result).to eq(
        error_code: "image_missing",
        error_category: "image_error"
      )
    end

    it '未定義エラーは system_error にフォールバックする' do
      result = described_class.map("unknown_error")

      expect(result).to eq(
        error_code: "unknown_error",
        error_category: "system_error"
      )
    end

    it 'nil は unexpected_error に変換される' do
      result = described_class.map(nil)

      expect(result).to eq(
        error_code: "unexpected_error",
        error_category: "system_error"
      )
    end

    it 'symbol は string に正規化される' do
      result = described_class.map(:ocr_timeout)

      expect(result).to eq(
        error_code: "ocr_timeout",
        error_category: "ocr_error"
      )
    end
  end
end
