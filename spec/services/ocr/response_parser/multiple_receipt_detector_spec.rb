require 'rails_helper'

RSpec.describe Ocr::ResponseParser::MultipleReceiptDetector do
  def fixture_pages(name)
    JSON.parse(Rails.root.join("spec/fixtures/ocr/#{name}.json").read).dig('analyzeResult', 'pages')
  end

  let(:profile) { ReceiptAnalysisProfiles.default }

  describe '.call' do
    it 'detects separated receipt clusters from the existing fixture' do
      expect(described_class.call(pages: fixture_pages('multi_receipts_in_one_image'), profile: profile)).to eq(true)
    end

    it 'does not flag representative single-receipt fixtures' do
      %w[single_tax_receipt long_receipt rotated_receipt blurred_receipt].each do |fixture_name|
        expect(described_class.call(pages: fixture_pages(fixture_name), profile: profile)).to eq(false), fixture_name
      end
    end

    it 'returns false for malformed pages without broadening the rescued errors' do
      aggregate_failures do
        expect(described_class.call(pages: nil, profile: profile)).to eq(false)
        expect(described_class.call(pages: [ nil ], profile: profile)).to eq(false)
        expect(described_class.call(pages: [ { 'width' => 0, 'height' => 0, 'lines' => [] } ], profile: profile)).to eq(false)
      end
    end

    it 'uses the injected profile patterns' do
      no_anchor_profile = double(
        'receipt analysis profile',
        ocr_merchant_anchor_pattern: /\A\z/,
        ocr_datetime_anchor_pattern: /\A\z/,
        ocr_subtotal_anchor_pattern: /\A\z/,
        ocr_total_anchor_pattern: /\A\z/,
        ocr_tax_anchor_pattern: /\A\z/,
        ocr_payment_anchor_pattern: /\A\z/
      )

      expect(
        described_class.call(
          pages: fixture_pages('multi_receipts_in_one_image'),
          profile: no_anchor_profile
        )
      ).to eq(false)
    end

    it 'does not mutate the OCR pages' do
      pages = fixture_pages('multi_receipts_in_one_image')
      original = pages.deep_dup

      described_class.call(pages: pages, profile: profile)

      expect(pages).to eq(original)
    end
  end
end
