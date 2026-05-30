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
        expect(result[:full_context_lines]).to eq(
          [
            { index: 0, text: 'Recify Mart 新宿店', next_text: '東京都新宿区1-2-3' },
            { index: 1, text: '東京都新宿区1-2-3', previous_text: 'Recify Mart 新宿店', next_text: '2026/05/20 12:34' },
            { index: 2, text: '2026/05/20 12:34', previous_text: '東京都新宿区1-2-3', next_text: 'コーヒー 180' },
            { index: 3, text: 'コーヒー 180', previous_text: '2026/05/20 12:34', next_text: 'パン 220' },
            { index: 4, text: 'パン 220', previous_text: 'コーヒー 180', next_text: '合計 400' },
            { index: 5, text: '合計 400', previous_text: 'パン 220', next_text: 'クレジット' },
            { index: 6, text: 'クレジット', previous_text: '合計 400' }
          ]
        )
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
        expect(result[:adjustment_candidates]).to eq([])
        expect(result.dig(:meta, :item_count)).to eq(2)
        expect(result.dig(:meta, :adjustment_candidate_count)).to eq(0)
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
        expect(result[:full_context_lines].size).to be <= described_class::MAX_FULL_CONTEXT_LINES
        expect(result[:items]).not_to be_empty
        expect(result.dig(:meta, :item_count)).to eq(result[:items].size)
        expect(result.dig(:meta, :confidence_summary, :items_average)).to eq(expected_average)
        expect(result[:items]).to all(include(:matched_content_lines, :matched_filtered_content_lines))
      end
    end

    it 'adjustment_context_linesは返品レシートでもfull_context_linesと同じ広い文脈を返す' do
      raw_json = JSON.parse(Rails.root.join('spec/fixtures/ocr/return_receipt.json').read)
      parsed_ocr_result = Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call

      result = described_class.build(parsed_ocr_result)
      texts = result[:adjustment_context_lines].map { |line| line[:text] }

      aggregate_failures do
        expect(result[:adjustment_context_lines]).to eq(result[:full_context_lines])
        expect(texts).to include('返品(液体洗剤)', '▲980')
        expect(result[:adjustment_context_lines]).to all(include(:index, :text))
      end
    end

    it '配送・袋代レシートでもadjustment_context_linesをキーワード候補に限定しない' do
      raw_json = JSON.parse(Rails.root.join('spec/fixtures/ocr/delivery_and_bag_fee_receipt.json').read)
      parsed_ocr_result = Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call

      result = described_class.build(parsed_ocr_result)
      texts = result[:adjustment_context_lines].map { |line| line[:text] }

      aggregate_failures do
        expect(result[:adjustment_context_lines]).to eq(result[:full_context_lines])
        expect(texts).to include('レジ袋代', '¥10', '配送料', '¥550')
      end
    end

    it 'サービス料・深夜料金レシートでもfiltered_contentから落ちる金額行をfull_context_linesに残す' do
      raw_json = JSON.parse(Rails.root.join('spec/fixtures/ocr/service_and_late_night_receipt.json').read)
      parsed_ocr_result = Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call

      result = described_class.build(parsed_ocr_result)
      texts = result[:adjustment_context_lines].map { |line| line[:text] }
      full_context_texts = result[:full_context_lines].map { |line| line[:text] }

      aggregate_failures do
        expect(result[:adjustment_context_lines]).to eq(result[:full_context_lines])
        expect(texts).to include('サービス料10%', '¥486', '深夜料金10%')
        expect(result[:filtered_content]).not_to include('¥486')
        expect(full_context_texts).to include('サービス料10%', '¥486', '深夜料金10%')
      end
    end

    it 'OCR parserのadjustment_candidatesをAI入力へ渡す' do
      raw_json = JSON.parse(Rails.root.join('spec/fixtures/ocr/service_and_late_night_receipt.json').read)
      parsed_ocr_result = Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call

      result = described_class.build(parsed_ocr_result)

      aggregate_failures do
        expect(result[:adjustment_candidates]).to include(
          hash_including(
            source_text: 'サービス料10%',
            amount: 486,
            sign_hint: 'surcharge',
            tax_rate_hint: BigDecimal('0.1'),
            neighboring_texts: hash_including(next_text: '¥486')
          ),
          hash_including(
            source_text: '深夜料金10%',
            amount: 486,
            sign_hint: 'surcharge',
            tax_rate_hint: BigDecimal('0.1')
          )
        )
        expect(result.dig(:meta, :adjustment_candidate_count)).to eq(2)
      end
    end

    it 'キーワード未登録の短い調整候補もadjustment_context_linesとfull_context_linesに残す' do
      ocr_result[:lines] = [
        'サンプル店舗',
        '小計',
        '¥1,000',
        'ミッドナイトチャージ',
        '¥100',
        '合計',
        '¥1,100'
      ]

      result = described_class.build(ocr_result)
      full_context_texts = result[:full_context_lines].map { |line| line[:text] }
      adjustment_context_texts = result[:adjustment_context_lines].map { |line| line[:text] }

      aggregate_failures do
        expect(result[:adjustment_context_lines]).to eq(result[:full_context_lines])
        expect(result[:filtered_content]).not_to include('¥100')
        expect(adjustment_context_texts).to include('ミッドナイトチャージ', '¥100')
        expect(full_context_texts).to include('ミッドナイトチャージ', '¥100')
      end
    end

    it '海外風の未知表記もキーワード抽出に依存せず文脈として残す' do
      ocr_result[:lines] = [
        'Sample Store',
        'Subtotal',
        '$20.00',
        'After hours surcharge',
        '$3.00',
        'Manual adjustment',
        '-$2.00',
        'Total',
        '$21.00'
      ]

      result = described_class.build(ocr_result)
      texts = result[:adjustment_context_lines].map { |line| line[:text] }

      aggregate_failures do
        expect(result[:adjustment_context_lines]).to eq(result[:full_context_lines])
        expect(texts).to include('After hours surcharge', '$3.00', 'Manual adjustment', '-$2.00')
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

    it 'filtered item matchingをmatched_content_linesとmatched_filtered_content_linesで共有する' do
      builder = described_class.new(ocr_result)

      allow(builder).to receive(:item_related_lines).and_call_original

      builder.build

      expect(builder).to have_received(:item_related_lines).exactly(2).times
    end

    it 'matched line配列は出力内で共有しない' do
      result = described_class.build(ocr_result)
      item = result[:items].first

      aggregate_failures do
        expect(item[:matched_content_lines]).to eq([ 'コーヒー 180' ])
        expect(item[:matched_filtered_content_lines]).to eq([ 'コーヒー 180' ])
        expect(item[:matched_content_lines]).not_to equal(item[:matched_filtered_content_lines])
      end
    end
  end
end
