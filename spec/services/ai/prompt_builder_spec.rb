require 'rails_helper'

RSpec.describe Ai::PromptBuilder do
  let(:ocr_result) do
    {
      success: true,
      raw_text: <<~TEXT,
        Recify Mart 新宿店
        東京都新宿区1-2-3
        2026/05/20 12:34
        コーヒー 180
        パン 220
        合計 400
        クレジット
      TEXT
      lines: [
        'Recify Mart 新宿店',
        '東京都新宿区1-2-3',
        '2026/05/20 12:34',
        'コーヒー 180',
        'パン 220',
        '合計 400',
        'クレジット'
      ],
      candidates: {
        store_name: { value: 'Recify Mart', confidence: 0.9 },
        purchased_at_text: { value: '2026-05-20 12:34', confidence: 0.8 },
        payment_method: { value: 'credit_card', confidence: 0.7 },
        payment_method_text: 'クレジット',
        total_amount: 400,
        country_region: 'JPN',
        items: [
          {
            raw_text: 'コーヒー',
            price: '180',
            quantity: '1',
            line_total: '180',
            confidence: '0.9'
          },
          {
            raw_text: 'パン',
            price: 220,
            quantity: 1,
            line_total: 220,
            confidence: 0.6
          }
        ]
      },
      meta: {
        provider: 'fixture',
        model: 'test-model'
      }
    }
  end

  describe '.build' do
    it '既存のPromptBuilder出力仕様を維持する' do
      result = described_class.build(ocr_result)

      aggregate_failures do
        expect(result[:filtered_content]).to eq(<<~TEXT.chomp)
          Recify Mart 新宿店
          東京都新宿区1-2-3
          コーヒー 180
          パン 220
          クレジット
        TEXT
        expect(result[:items]).to eq(
          [
            {
              index: 0,
              raw_text: 'コーヒー',
              price: 180,
              quantity: 1,
              line_total: 180,
              confidence: 0.9,
              matched_content_lines: [ 'コーヒー 180' ],
              matched_filtered_content_lines: [ 'コーヒー 180' ]
            },
            {
              index: 1,
              raw_text: 'パン',
              price: 220,
              quantity: 1,
              line_total: 220,
              confidence: 0.6,
              matched_content_lines: [ 'パン 220' ],
              matched_filtered_content_lines: [ 'パン 220' ]
            }
          ]
        )
        expect(result.dig(:meta, :item_count)).to eq(2)
        expect(result.dig(:meta, :confidence_summary, :items_average)).to eq(0.75)
      end
    end

    it '長いレシートfixtureでもitem数とconfidence summaryの互換性を保つ' do
      raw_json = JSON.parse(Rails.root.join('spec/fixtures/ocr/long_receipt.json').read)
      parsed_ocr_result = Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call

      result = described_class.build(parsed_ocr_result)
      item_confidences = result[:items].filter_map { |item| item[:confidence] }
      expected_average = (item_confidences.sum / item_confidences.size.to_f).round(3)

      aggregate_failures do
        expect(result[:filtered_content].lines.size).to be <= described_class::MAX_FILTERED_CONTENT_LINES
        expect(result[:items]).not_to be_empty
        expect(result.dig(:meta, :item_count)).to eq(result[:items].size)
        expect(result.dig(:meta, :confidence_summary, :items_average)).to eq(expected_average)
        expect(result[:items]).to all(include(:matched_content_lines, :matched_filtered_content_lines))
      end
    end
  end

  describe '#build' do
    it 'items payloadを派生情報のために再計算しない' do
      builder = described_class.new(ocr_result)

      allow(builder).to receive(:normalize_item_payload).and_call_original

      builder.build

      expect(builder).to have_received(:normalize_item_payload).exactly(2).times
    end

    it 'filtered_content_linesを再計算しない' do
      builder = described_class.new(ocr_result)

      allow(builder).to receive(:removable_noise_line?).and_call_original

      builder.build

      expect(builder).to have_received(:removable_noise_line?).exactly(ocr_result[:lines].size).times
    end
  end
end
