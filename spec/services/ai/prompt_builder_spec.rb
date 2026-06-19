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

    it 'SystemSettingsのprompt上限を参照する' do
      create(:system_setting, key: 'limits.ai_prompt_filtered_content_lines_max', value: SystemSettings.stored_value(5))
      create(:system_setting, key: 'limits.ai_prompt_full_context_lines_max', value: SystemSettings.stored_value(10))
      create(:system_setting, key: 'limits.ai_prompt_raw_text_length_max', value: SystemSettings.stored_value(500))
      create(:system_setting, key: 'limits.ai_prompt_purchase_candidates_max', value: SystemSettings.stored_value(2))
      raw_text = Array.new(30) do |index|
        date_text = format('2026/05/%02d 10:00', (index % 20) + 1)
        "#{date_text} 商品#{index} #{index + 100}"
      end.join("\n")

      result = described_class.build({
        success: true,
        raw_text: raw_text,
        candidates: {
          items: []
        }
      })

      aggregate_failures do
        expect(result[:filtered_content].lines.size).to be <= 5
        expect(result[:full_context_lines].size).to eq(10)
        expect(result.dig(:purchase, :purchased_at_candidates).size).to eq(2)
        expect(result.dig(:meta, :raw_text_length)).to be <= 500
      end
    end

    it '顧客向け施設名候補と運営主体候補をAI入力で分ける' do
      parking_ocr_result = ocr_result.deep_merge(
        lines: [
          'サンプル公園',
          '駐車場',
          '領収書',
          '登録番号:t7490001001867',
          '東京都中央区銀座1-1-1',
          '駐車券自家用車等',
          '現 計',
          'サンプル公園指定管理者',
          '株式会社',
          'サンプル管理'
        ],
        candidates: {
          store_name: "株式会社\nサンプル管理",
          store_address: '東京都中央区銀座1-1-1',
          total_amount: 500,
          items: [
            { raw_text: '駐車券自家用車等', line_total: 500, confidence: 0.975 }
          ]
        }
      )

      result = described_class.build(parking_ocr_result)
      store_payload = result[:store]

      aggregate_failures do
        expect(store_payload[:customer_facing_store_candidates]).to include('サンプル公園駐車場')
        expect(store_payload[:store_candidates].first).to eq('サンプル公園駐車場')
        expect(store_payload[:operator_candidates]).to include('株式会社サンプル管理')
        expect(store_payload[:store_candidates]).not_to include("株式会社\nサンプル管理")
      end
    end

    it '印字されたブランド名と場所名を結合した候補を短いOCR店舗名より優先する' do
      branch_ocr_result = ocr_result.deep_merge(
        lines: [
          'サンプル食堂',
          '株式会社サンプル食堂',
          'サンプル通り',
          '東京都渋谷区道玄坂1-2-3',
          'お客様相談室 0120-498-007',
          '登録番号:t2010401093920',
          '店no:0003077'
        ],
        candidates: {
          store_name: 'サンプル食堂',
          store_address: '東京都渋谷区道玄坂1-2-3',
          total_amount: 1510,
          items: []
        }
      )

      result = described_class.build(branch_ocr_result)
      store_payload = result[:store]

      aggregate_failures do
        expect(store_payload[:store_candidates].first).to eq('サンプル食堂 サンプル通り')
        expect(store_payload[:customer_facing_store_candidates]).to include('サンプル食堂 サンプル通り')
        expect(store_payload[:branch_name_candidates]).to include('サンプル通り')
        expect(store_payload[:operator_candidates]).to include('株式会社サンプル食堂')
        expect(store_payload[:operator_candidates]).not_to include('株式会社サンプル食堂サンプル通り')
      end
    end

    it 'mixed scriptのブランド名と日本語支店名を印字どおり空白ありで結合する' do
      mixed_script_ocr_result = ocr_result.deep_merge(
        lines: [
          'SampleMart',
          '中央南三丁目店',
          '領',
          '収',
          '証',
          '合 計',
          '東京都国分寺市サンプル1-2-3',
          '領収証'
        ],
        candidates: {
          store_name: '中央南三丁目店',
          store_address: '東京都国分寺市サンプル1-2-3',
          total_amount: 844,
          items: []
        }
      )

      result = described_class.build(mixed_script_ocr_result)
      store_payload = result[:store]

      aggregate_failures do
        expect(store_payload[:store_candidates].first).to eq('SampleMart 中央南三丁目店')
        expect(store_payload[:customer_facing_store_candidates]).to include('SampleMart 中央南三丁目店')
        expect(store_payload[:customer_facing_store_candidates]).not_to include('SampleMart中央南三丁目店')
        expect(store_payload[:branch_name_candidates]).to include('中央南三丁目店')
        expect(store_payload[:branch_name_candidates] & [ '領', '収', '証', '合 計' ]).to be_empty
      end
    end

    it '店舗名表記ポリシーとして顧客向けブランドと支店・場所名だけを候補化する' do
      policy_ocr_result = ocr_result.deep_merge(
        lines: [
          'SampleMart',
          '中央南三丁目店',
          'Managed by',
          'Sample Retail LLC',
          '東京都国分寺市サンプル1-2-3',
          '領収証'
        ],
        candidates: {
          store_name: '中央南三丁目店',
          store_address: '東京都国分寺市サンプル1-2-3',
          country_region: 'JPN',
          total_amount: 844,
          items: []
        }
      )

      result = described_class.build(policy_ocr_result)
      store_payload = result[:store]

      aggregate_failures do
        expect(store_payload[:store_candidates].first).to eq('SampleMart 中央南三丁目店')
        expect(store_payload[:customer_facing_store_candidates]).to include('SampleMart 中央南三丁目店')
        expect(store_payload[:branch_name_candidates]).to include('中央南三丁目店')
        expect(store_payload[:operator_candidates]).to include('Sample Retail LLC')
        expect(store_payload[:store_candidates]).not_to include('Sample Retail LLC')
      end
    end

    it '英字ロゴ行とローカル完結店舗名が重複する場合はローカル店舗名を先に候補化する' do
      local_complete_ocr_result = ocr_result.deep_merge(
        lines: [
          'SampleBrand',
          'サンプルブランド東京中央店',
          'TEL 000-0000-0000',
          '領収証'
        ],
        candidates: {
          store_name: 'SampleBrand サンプルブランド東京中央店',
          country_region: 'JPN',
          total_amount: 100,
          items: []
        }
      )

      result = described_class.build(local_complete_ocr_result)
      store_payload = result[:store]

      aggregate_failures do
        expect(store_payload[:store_candidates].first).to eq('サンプルブランド東京中央店')
        expect(store_payload[:customer_facing_store_candidates].first).to eq('サンプルブランド東京中央店')
        expect(store_payload[:customer_facing_store_candidates]).to include('SampleBrand')
      end
    end

    it 'ブランドのみ・施設名・ブランド+locationをOCR表記どおり候補化し未印字suffixを足さない' do
      examples = [
        {
          lines: [ 'SampleMart', 'Receipt' ],
          store_name: 'SampleMart',
          expected: 'SampleMart'
        },
        {
          lines: [ 'サンプル浜公園', '駐車場', '領収証' ],
          store_name: 'サンプル浜公園駐車場',
          expected: 'サンプル浜公園駐車場'
        },
        {
          lines: [ 'Sample Cafe Downtown', 'Receipt' ],
          store_name: 'Sample Cafe Downtown',
          expected: 'Sample Cafe Downtown'
        },
        {
          lines: [ 'SampleMart Downtown', 'Receipt' ],
          store_name: 'SampleMart Downtown',
          expected: 'SampleMart Downtown'
        }
      ]

      examples.each do |example|
        result = described_class.build(
          ocr_result.deep_merge(
            lines: example[:lines],
            candidates: {
              store_name: example[:store_name],
              country_region: 'USA',
              total_amount: 100,
              items: []
            }
          )
        )
        store_payload = result[:store]

        aggregate_failures(example[:expected]) do
          expect(store_payload[:store_candidates].first).to eq(example[:expected])
          expect(store_payload[:customer_facing_store_candidates]).to include(example[:expected])
          expect(store_payload[:store_candidates]).not_to include("#{example[:expected]} Store")
          expect(store_payload[:store_candidates]).not_to include("#{example[:expected]} Branch")
        end
      end
    end

    it 'ロゴ由来の孤立1文字をstore候補から除外し、Marketを含む英字ブランドを候補に残す' do
      logo_fragment_ocr_result = ocr_result.deep_merge(
        lines: [
          'プ',
          'Sample Life Market',
          'サンプルライフマーケット 恵比寿店',
          '東京都渋谷区サンプル1-2-3',
          'サンプルプラザビルB1F',
          '毎度ありがとうございます。',
          '領 収 証'
        ],
        candidates: {
          store_name: 'Sample Life Market',
          store_address: '東京都渋谷区サンプル1-2-3',
          total_amount: 1288,
          items: []
        }
      )

      result = described_class.build(logo_fragment_ocr_result)
      store_payload = result[:store]

      aggregate_failures do
        expect(store_payload[:customer_facing_store_candidates]).to include(
          'Sample Life Market',
          'サンプルライフマーケット 恵比寿店'
        )
        expect(store_payload[:store_candidates]).to include('Sample Life Market')
        expect(store_payload[:store_candidates] & [ 'プ', 'プ Sample Life Market', 'サンプルプラザビルB1F', '領 収 証', '毎度ありがとうございます。' ]).to be_empty
        expect(store_payload[:branch_name_candidates]).not_to include('プ')
        expect(store_payload[:branch_name_candidates]).not_to include('サンプルプラザビルB1F')
      end
    end

    it '記号始まりの短いロゴ片をcustomer-facing候補から除外する' do
      logo_fragment_ocr_result = ocr_result.deep_merge(
        lines: [
          '/smp',
          'サンプル中央店',
          'TEL 000-0000-0000',
          '領収証'
        ],
        candidates: {
          store_name: '/smp サンプル中央店',
          total_amount: 100,
          items: []
        }
      )

      result = described_class.build(logo_fragment_ocr_result)
      store_payload = result[:store]

      aggregate_failures do
        expect(store_payload[:customer_facing_store_candidates]).to include('サンプル中央店')
        expect(store_payload[:customer_facing_store_candidates]).not_to include('/smp')
        expect(store_payload[:store_candidates]).not_to include('/smp')
        expect(store_payload[:branch_name_candidates]).not_to include('/smp')
      end
    end

    it '販促文や営業時間案内をstore候補やbranch候補に含めない' do
      message_line_ocr_result = ocr_result.deep_merge(
        lines: [
          'プロの品質とプロの価格',
          'サンプルスーパー 東京中央店',
          '毎日安い!この価格!',
          '営業時間AM9:00〜PM9:00',
          '001001東京中央店',
          '領収証'
        ],
        candidates: {
          store_name: 'プロの品質とプロの価格 001001東京中央店',
          total_amount: 500,
          items: []
        }
      )

      result = described_class.build(message_line_ocr_result)
      store_payload = result[:store]

      aggregate_failures do
        expect(store_payload[:customer_facing_store_candidates]).to include('サンプルスーパー 東京中央店')
        expect(store_payload[:store_candidates]).to include('サンプルスーパー 東京中央店')
        expect(store_payload[:store_candidates]).not_to include('プロの品質とプロの価格')
        expect(store_payload[:store_candidates]).not_to include('毎日安い!この価格!')
        expect(store_payload[:branch_name_candidates]).not_to include('毎日安い!この価格!')
        expect(store_payload[:branch_name_candidates]).not_to include('営業時間AM9:00~PM9:00')
      end
    end

    it 'OCR店名が壊れていてもoperator法人名からブランドと場所名の候補を生成する' do
      broken_brand_ocr_result = ocr_result.deep_merge(
        lines: [
          '小乐',
          '株式会社サンプル食堂',
          'サンプル通り',
          '東京都渋谷区道玄坂1-2-3',
          'お客様相談室',
          '0120-498-007',
          '登録番号:t2010401093920'
        ],
        candidates: {
          store_name: '小乐 サンプル通り',
          store_address: '東京都渋谷区道玄坂1-2-3',
          total_amount: 1391,
          items: []
        }
      )

      result = described_class.build(broken_brand_ocr_result)
      store_payload = result[:store]

      aggregate_failures do
        expect(store_payload[:store_candidates].first).to eq('サンプル食堂 サンプル通り')
        expect(store_payload[:customer_facing_store_candidates]).to include(
          'サンプル食堂 サンプル通り',
          'サンプル食堂'
        )
        expect(store_payload[:operator_candidates]).to include('株式会社サンプル食堂')
        expect(store_payload[:store_candidates]).not_to include('サンプル食堂 サンプル通り店')
      end
    end

    it 'operator法人名だけではブランド候補をstore候補の先頭にしない' do
      operator_only_ocr_result = ocr_result.deep_merge(
        lines: [
          '株式会社サンプル食堂',
          '領収証',
          '合計 ¥500'
        ],
        candidates: {
          store_name: '株式会社サンプル食堂',
          total_amount: 500,
          items: []
        }
      )

      result = described_class.build(operator_only_ocr_result)
      store_payload = result[:store]

      aggregate_failures do
        expect(store_payload[:store_candidates].first).to eq('株式会社サンプル食堂')
        expect(store_payload[:customer_facing_store_candidates]).not_to include('サンプル食堂')
      end
    end

    it '海外風のoperator法人名からブランドと場所名の候補を生成する' do
      overseas_broken_brand_ocr_result = ocr_result.deep_merge(
        lines: [
          'Starbueks',
          'Sample Coffee Company LLC',
          'Downtown',
          'Receipt',
          'Total $8.40'
        ],
        candidates: {
          store_name: 'Starbueks Downtown',
          country_region: 'USA',
          total_amount: 8.40,
          items: []
        }
      )

      result = described_class.build(overseas_broken_brand_ocr_result)
      store_payload = result[:store]

      aggregate_failures do
        expect(store_payload[:store_candidates].first).to eq('Sample Coffee Company Downtown')
        expect(store_payload[:customer_facing_store_candidates]).to include('Sample Coffee Company')
        expect(store_payload[:store_candidates]).not_to include('Sample Coffee Company Downtown Store')
      end
    end

    it '業態説明行を除外し、ブランド名と施設内の場所名を結合した候補を優先する' do
      facility_ocr_result = ocr_result.deep_merge(
        lines: [
          'イタリアンワイン&カフェレストラン',
          'サンプルレストラン',
          'サンプルモール渋谷',
          'tel 03-0000-0000',
          '領収証'
        ],
        candidates: {
          store_name: 'サンプルレストラン',
          total_amount: 3480,
          items: []
        }
      )

      result = described_class.build(facility_ocr_result)
      store_payload = result[:store]

      aggregate_failures do
        expect(store_payload[:store_candidates].first).to eq('サンプルレストラン サンプルモール渋谷')
        expect(store_payload[:customer_facing_store_candidates]).to include('サンプルレストラン サンプルモール渋谷')
        expect(store_payload[:store_candidates]).not_to include('イタリアンワイン&カフェレストランサンプルレストランサンプルモール渋谷')
        expect(store_payload[:branch_name_candidates]).to include('サンプルモール渋谷')
      end
    end

    it '海外風のブランド名と場所名は印字どおり結合し、未印字のsuffixを候補へ足さない' do
      overseas_ocr_result = ocr_result.deep_merge(
        lines: [
          'Sample Coffee',
          'Downtown',
          'Receipt',
          'Total $8.40'
        ],
        candidates: {
          store_name: 'Sample Coffee',
          country_region: 'USA',
          total_amount: 8.40,
          items: []
        }
      )

      result = described_class.build(overseas_ocr_result)
      store_payload = result[:store]

      aggregate_failures do
        expect(store_payload[:store_candidates].first).to eq('Sample Coffee Downtown')
        expect(store_payload[:store_candidates]).not_to include('Sample Coffee Downtown Store')
        expect(store_payload[:store_candidates]).not_to include('Sample Coffee Downtown Branch')
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

    it 'PaymentMethods query field由来の補助候補をAI入力へ渡す' do
      ocr_result[:candidates][:payment_candidates] = [
        {
          source: 'query_field',
          field_name: 'PaymentMethods',
          method: 'PayPay ¥400',
          raw_text: 'PayPay ¥400',
          content: '支払い PayPay ¥400',
          confidence: '0.84'
        }
      ]

      result = described_class.build(ocr_result)

      expect(result.dig(:payment, :payment_candidates)).to include(
        hash_including(
          source: 'query_field',
          field_name: 'PaymentMethods',
          method: 'PayPay ¥400',
          raw_text: 'PayPay ¥400',
          content: '支払い PayPay ¥400',
          confidence: 0.84
        )
      )
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
