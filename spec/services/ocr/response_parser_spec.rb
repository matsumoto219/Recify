require 'rails_helper'

RSpec.describe Ocr::ResponseParser do
  describe '#call' do
    let(:raw_response) do
      {
        'status' => 'succeeded',
        'analyzeResult' => {
          'content' => <<~TEXT,
            サンプルストア
            東京都渋谷区1-2-3
            TEL 03-1234-5678
            2026/04/02 12:34
            コーヒー 180
            サンド 550 x2
            小計 1180
            消費税 80
            チップ 100
            合計 1280
            Master
          TEXT
          'documents' => [
            {
              'docType' => 'receipt.retailMeal',
              'fields' => {
                'MerchantName' => { 'valueString' => 'サンプルストア' },
                'MerchantAddress' => {
                  'valueString' => '東京都渋谷区1-2-3',
                  'valueAddress' => {
                    'state' => '東京都',
                    'city' => '渋谷区',
                    'streetAddress' => '1-2-3'
                  }
                },
                'MerchantPhoneNumber' => { 'valueString' => '03-1234-5678' },
                'TransactionDate' => { 'valueDate' => '2026-04-02' },
                'TransactionTime' => { 'valueTime' => '12:34' },
                'Total' => { 'valueCurrency' => { 'amount' => 1280, 'currencyCode' => 'jpy' } },
                'Subtotal' => { 'valueCurrency' => { 'amount' => 1180, 'currencyCode' => 'JPY' } },
                'TotalTax' => { 'valueCurrency' => { 'amount' => 80, 'currencyCode' => 'JPY' } },
                'Tip' => { 'valueCurrency' => { 'amount' => 100, 'currencyCode' => 'JPY' } },
                'CountryRegion' => { 'valueCountryRegion' => 'JPN' },
                'ReceiptType' => { 'valueString' => 'Meal' },
                'Payments' => {
                  'valueArray' => [
                    {
                      'valueObject' => {
                        'Method' => { 'valueString' => 'CreditCard' },
                        'Amount' => { 'valueCurrency' => { 'amount' => 1280, 'currencyCode' => 'JPY' } }
                      }
                    }
                  ]
                },
                'TaxDetails' => {
                  'valueArray' => [
                    {
                      'valueObject' => {
                        'Description' => { 'valueString' => 'Sales Tax' },
                        'Amount' => { 'valueCurrency' => { 'amount' => 80, 'currencyCode' => 'JPY' } },
                        'Rate' => { 'valueNumber' => 10 },
                        'NetAmount' => { 'valueCurrency' => { 'amount' => 800, 'currencyCode' => 'JPY' } }
                      }
                    }
                  ]
                },
                'Items' => {
                  'valueArray' => [
                    {
                      'valueObject' => {
                        'Description' => { 'valueString' => 'コーヒー' },
                        'Quantity' => { 'valueNumber' => 1 },
                        'QuantityUnit' => { 'valueString' => '杯' },
                        'Price' => { 'valueCurrency' => { 'amount' => 180, 'currencyCode' => 'JPY' } },
                        'TotalPrice' => { 'valueCurrency' => { 'amount' => 180, 'currencyCode' => 'JPY' } },
                        'ProductCode' => { 'valueString' => 'C001' }
                      },
                      'confidence' => 0.98
                    },
                    {
                      'valueObject' => {
                        'Description' => { 'valueString' => 'サンド' },
                        'Quantity' => { 'valueNumber' => 2 },
                        'QuantityUnit' => { 'valueString' => '個' },
                        'Price' => { 'valueCurrency' => { 'amount' => 550, 'currencyCode' => 'JPY' } },
                        'TotalPrice' => { 'valueCurrency' => { 'amount' => 1100, 'currencyCode' => 'JPY' } },
                        'ProductCode' => { 'valueString' => 'S001' }
                      },
                      'confidence' => 0.97
                    }
                  ]
                }
              }
            }
          ]
        }
      }
    end

    it 'Azureレスポンスを内部形式へ厳密に変換する' do
      result = described_class.new(response: raw_response, provider: 'azure_document_intelligence').call

      aggregate_failures do
        expect(result[:success]).to eq(true)
        expect(result[:raw_text]).to include('サンプルストア')
        expect(result[:lines]).to include('コーヒー 180', 'サンド 550 x2')
        expect(result[:lines]).to include('master')
        expect(result[:case_preserved_lines]).to include('Master')
        expect(result[:error_code]).to be_nil
        expect(result.dig(:meta, :provider)).to eq('azure_document_intelligence')
      end

      candidates = result[:candidates]
      first_item = candidates[:items].first
      second_item = candidates[:items].second
      first_payment = candidates[:payments].first
      first_tax_detail = candidates[:tax_details].first

      aggregate_failures do
        expect(candidates[:store_name]).to eq('サンプルストア')
        expect(candidates[:store_address]).to eq('東京都渋谷区1-2-3')
        expect(candidates[:store_address_components]).to eq(
          'state' => '東京都',
          'city' => '渋谷区',
          'streetAddress' => '1-2-3'
        )
        expect(candidates[:store_phone_number]).to eq('03-1234-5678')
        expect(candidates[:purchased_at_text]).to eq('2026-04-02 12:34')
        expect(candidates[:total_amount]).to eq(1280)
        expect(candidates[:subtotal_amount]).to eq(1180)
        expect(candidates[:tax_amount]).to eq(80)
        expect(candidates[:tax_rate]).to eq(10)
        expect(candidates[:tip_amount]).to eq(100)
        expect(candidates[:currency_code]).to eq('JPY')
        expect(candidates[:country_region]).to eq('JPN')
        expect(candidates[:receipt_type]).to eq('Meal')
        expect(candidates[:payment_method_text]).to eq('master')
        expect(result.dig(:meta, :doc_type)).to eq('receipt.retailMeal')
      end

      aggregate_failures do
        expect(candidates[:items].size).to eq(2)
        expect(first_item[:raw_text]).to eq('コーヒー')
        expect(first_item[:price]).to eq(180)
        expect(first_item[:quantity]).to eq(1)
        expect(first_item[:quantity_unit_code]).to eq('each')
        expect(first_item[:product_code]).to eq('C001')
        expect(first_item[:line_total]).to eq(180)
        expect(first_item[:confidence]).to eq(0.98)

        expect(second_item[:raw_text]).to eq('サンド')
        expect(second_item[:price]).to eq(550)
        expect(second_item[:quantity]).to eq(2)
        expect(second_item[:quantity_unit_code]).to eq('each')
        expect(second_item[:product_code]).to eq('S001')
        expect(second_item[:line_total]).to eq(1100)
        expect(second_item[:confidence]).to eq(0.97)
      end

      aggregate_failures do
        expect(candidates[:payments].size).to eq(1)
        expect(first_payment[:method]).to eq('CreditCard')
        expect(first_payment[:amount]).to eq(1280)

        expect(candidates[:tax_details].size).to eq(1)
        expect(first_tax_detail[:description]).to eq('Sales Tax')
        expect(first_tax_detail[:amount]).to eq(80)
        expect(first_tax_detail[:rate]).to eq(10)
        expect(first_tax_detail[:net_amount]).to eq(800)
      end
    end

    it 'AI向けに小文字化前のOCR行を保持しつつ既存linesは小文字正規化する' do
      response = raw_response.deep_dup
      response['analyzeResult']['content'] = <<~TEXT
        FamilyMart
        国分寺南町三丁目店
        エミフルMASAKI
        合計 400
      TEXT
      response['analyzeResult']['documents'].first['fields']['MerchantName'] = { 'valueString' => 'FamilyMart' }

      result = described_class.new(response: response).call

      aggregate_failures do
        expect(result[:lines]).to include('familymart', 'エミフルmasaki')
        expect(result[:case_preserved_lines]).to include('FamilyMart', 'エミフルMASAKI')
      end
    end

    it 'JSON文字列入力でも内部形式へ変換できる' do
      json_response = raw_response.to_json

      result = described_class.new(response: json_response, provider: 'azure_document_intelligence').call

      aggregate_failures do
        expect(result[:success]).to eq(true)
        expect(result.dig(:candidates, :store_name)).to eq('サンプルストア')
        expect(result.dig(:candidates, :total_amount)).to eq(1280)
        expect(result.dig(:candidates, :items)&.size).to eq(2)
        expect(result.dig(:meta, :provider)).to eq('azure_document_intelligence')
      end
    end

    it 'Recify内部のpolling metricsをmetaへ移す' do
      response = raw_response.deep_dup
      response[Ocr::Client::POLLING_METRICS_KEY] = {
        'elapsed_ms' => 3200,
        'poll_count' => 3,
        'final_status' => 'succeeded',
        'max_poll_count' => 20,
        'poll_interval' => 1.0,
        'total_poll_sleep_ms' => 5500,
        'max_poll_interval' => 3.0,
        'poll_backoff_factor' => 1.5,
        'reached_max_poll' => false,
        'retry_after_used' => true,
        'retry_count' => 1
      }

      result = described_class.new(response: response, provider: 'azure_document_intelligence').call

      expect(result.dig(:meta, :polling_metrics)).to eq(
        elapsed_ms: 3200,
        poll_count: 3,
        final_status: 'succeeded',
        max_poll_count: 20,
        poll_interval: 1.0,
        total_poll_sleep_ms: 5500,
        max_poll_interval: 3.0,
        poll_backoff_factor: 1.5,
        reached_max_poll: false,
        retry_after_used: true,
        retry_count: 1
      )
    end

    it 'Totalに通貨コードがない場合は周辺のvalueCurrencyから代表通貨を補完する' do
      raw_response.dig('analyzeResult', 'documents', 0, 'fields', 'Total', 'valueCurrency').delete('currencyCode')
      raw_response.dig('analyzeResult', 'documents', 0, 'fields', 'Subtotal', 'valueCurrency')['currencyCode'] = 'usd'

      result = described_class.new(response: raw_response, provider: 'azure_document_intelligence').call

      expect(result.dig(:candidates, :currency_code)).to eq('USD')
    end

    it 'fieldsが一部欠けていても lines や text から補助抽出できる' do
      partial_response = raw_response.deep_dup
      partial_response['analyzeResult']['content'] = <<~TEXT
        サンプルストア
        東京都渋谷区1-2-3
        TEL 03-1234-5678
        2026/04/02 12:34
        コーヒー 180
        サンド 550 x2
        小計 1180
        消費税 80
        合計 1280
        Mastercard
      TEXT
      fields = partial_response.dig('analyzeResult', 'documents', 0, 'fields')
      fields.delete('MerchantName')
      fields.delete('TransactionDate')
      fields.delete('TransactionTime')
      fields.delete('Total')
      fields.delete('Subtotal')
      fields.delete('TotalTax')
      fields.delete('Items')

      result = described_class.new(response: partial_response).call
      candidates = result[:candidates]

      aggregate_failures do
        expect(result[:success]).to eq(true)
        expect(result[:raw_text]).to include('サンプルストア')
        expect(result[:lines]).to include('コーヒー 180', 'サンド 550 x2')
        expect(candidates[:store_name]).to eq('サンプルストア')
        expect(candidates[:purchased_at_text]).to eq('2026-04-02 12:34')
        expect(candidates[:total_amount]).to eq(1280)
        expect(candidates[:subtotal_amount]).to eq(1180)
        expect(candidates[:tax_amount]).to eq(80)
        expect(candidates[:payment_method_text]).to eq('mastercard')
        expect(candidates[:items]).to eq([])
      end
    end

    it 'result.text と result.lines 形式でも抽出できる' do
      nested_response = {
        'status' => 'succeeded',
        'analyzeResult' => {
          'content' => "ネスト店舗\n2026-04-03 09:15\n合計 980\nVISA",
          'documents' => [
            {
              'fields' => {
                'MerchantName' => { 'valueString' => 'ネスト店舗' },
                'Total' => { 'valueCurrency' => { 'amount' => 980 } }
              }
            }
          ]
        }
      }

      result = described_class.new(response: nested_response).call
      candidates = result[:candidates]

      aggregate_failures do
        expect(result[:success]).to eq(true)
        expect(result[:raw_text]).to include('ネスト店舗')
        expect(result[:lines]).to eq([ 'ネスト店舗', '2026-04-03 09:15', '合計 980', 'visa' ])
        expect(candidates[:store_name]).to eq('ネスト店舗')
        expect(candidates[:purchased_at_text]).to eq('2026-04-03 09:15')
        expect(candidates[:total_amount]).to eq(980)
        expect(candidates[:payment_method_text]).to eq('visa')
      end
    end

    it '決済文言は lines を優先し、なければ raw_text 全体から抽出する' do
      line_priority_response = raw_response.deep_dup
      line_priority_response['analyzeResult']['content'] = <<~TEXT
        サンプルストア
        合計 1280
        VISA
        PayPay
      TEXT

      line_priority_result = described_class.new(response: line_priority_response).call

      raw_text_fallback_response = raw_response.deep_dup
      raw_text_fallback_response['analyzeResult']['content'] = <<~TEXT
        サンプルストア
        合計 1280
        お支払いはJCBです
      TEXT

      raw_text_fallback_result = described_class.new(response: raw_text_fallback_response).call

      aggregate_failures do
        expect(line_priority_result.dig(:candidates, :payment_method_text)).to eq('visa')
        expect(raw_text_fallback_result.dig(:candidates, :payment_method_text)).to eq('jcb')
      end
    end

    it 'PaymentMethods query fieldは確定支払い方法へ昇格せず補助候補として扱う' do
      query_field_response = raw_response.deep_dup
      query_field_response['analyzeResult']['content'] = <<~TEXT
        サンプルストア
        合計 1280
      TEXT
      fields = query_field_response.dig('analyzeResult', 'documents', 0, 'fields')
      fields['PaymentMethods'] = {
        'valueString' => 'PayPay ¥1,280',
        'content' => '支払い PayPay ¥1,280',
        'confidence' => 0.82
      }

      result = described_class.new(response: query_field_response).call

      aggregate_failures do
        expect(result.dig(:candidates, :payment_method_text)).to be_nil
        expect(result.dig(:candidates, :payment_candidates)).to include(
          hash_including(
            source: 'query_field',
            field_name: 'PaymentMethods',
            method: 'PayPay ¥1,280',
            raw_text: 'PayPay ¥1,280',
            content: '支払い PayPay ¥1,280',
            confidence: 0.82
          )
        )
      end
    end

    it 'fixtureのPaymentMethods query fieldも補助候補として扱う' do
      fixture_response = JSON.parse(Rails.root.join('spec/fixtures/ocr/zero_tax_receipt.json').read)

      result = described_class.new(response: fixture_response, provider: :fixture).call

      expect(result.dig(:candidates, :payment_candidates)).to include(
        hash_including(field_name: 'PaymentMethods', method: '現 金', source: 'query_field')
      )
    end

    it '購入日時の構造化fieldと日付/時刻分離行のfallbackを固定する' do
      fixture_response = JSON.parse(Rails.root.join('spec/fixtures/ocr/parser_boundary_receipt.json').read)

      structured_result = described_class.new(response: fixture_response, provider: :fixture).call

      date_only_response = fixture_response.deep_dup
      date_only_response.dig('analyzeResult', 'documents', 0, 'fields').delete('TransactionTime')
      date_only_result = described_class.new(response: date_only_response, provider: :fixture).call

      time_only_response = fixture_response.deep_dup
      time_only_response.dig('analyzeResult', 'documents', 0, 'fields').delete('TransactionDate')
      time_only_result = described_class.new(response: time_only_response, provider: :fixture).call

      line_fallback_response = fixture_response.deep_dup
      line_fallback_fields = line_fallback_response.dig('analyzeResult', 'documents', 0, 'fields')
      line_fallback_fields.delete('TransactionDate')
      line_fallback_fields.delete('TransactionTime')
      line_fallback_result = described_class.new(response: line_fallback_response, provider: :fixture).call

      nearby_fallback_response = fixture_response.deep_dup
      nearby_fallback_response['analyzeResult']['content'] = <<~TEXT
        OCR境界ストア
        2026年05月20日
        レジ 02
        18:42
        合計
        ¥1,900
      TEXT
      nearby_fallback_fields = nearby_fallback_response.dig('analyzeResult', 'documents', 0, 'fields')
      nearby_fallback_fields.delete('TransactionDate')
      nearby_fallback_fields.delete('TransactionTime')
      nearby_fallback_result = described_class.new(response: nearby_fallback_response, provider: :fixture).call

      fallback_date_only_response = fixture_response.deep_dup
      fallback_date_only_response['analyzeResult']['content'] = <<~TEXT
        OCR境界ストア
        2026年05月20日
        合計
        ¥1,900
      TEXT
      fallback_date_only_fields = fallback_date_only_response.dig('analyzeResult', 'documents', 0, 'fields')
      fallback_date_only_fields.delete('TransactionDate')
      fallback_date_only_fields.delete('TransactionTime')
      fallback_date_only_result = described_class.new(response: fallback_date_only_response, provider: :fixture).call

      fallback_time_only_response = fixture_response.deep_dup
      fallback_time_only_response['analyzeResult']['content'] = <<~TEXT
        OCR境界ストア
        18:42
        合計
        ¥1,900
      TEXT
      fallback_time_only_fields = fallback_time_only_response.dig('analyzeResult', 'documents', 0, 'fields')
      fallback_time_only_fields.delete('TransactionDate')
      fallback_time_only_fields.delete('TransactionTime')
      fallback_time_only_result = described_class.new(response: fallback_time_only_response, provider: :fixture).call

      noisy_fallback_response = fixture_response.deep_dup
      noisy_fallback_response['analyzeResult']['content'] = <<~TEXT
        OCR境界ストア
        2026 年 05 月 20 日(水)
        18 ： 42
        合計
        ¥1,900
      TEXT
      noisy_fallback_fields = noisy_fallback_response.dig('analyzeResult', 'documents', 0, 'fields')
      noisy_fallback_fields.delete('TransactionDate')
      noisy_fallback_fields.delete('TransactionTime')
      noisy_fallback_result = described_class.new(response: noisy_fallback_response, provider: :fixture).call

      distant_time_response = fixture_response.deep_dup
      distant_time_response['analyzeResult']['content'] = <<~TEXT
        OCR境界ストア
        2026年05月20日
        商品A
        ¥1,000
        合計
        ¥1,900
        18:42
      TEXT
      distant_time_fields = distant_time_response.dig('analyzeResult', 'documents', 0, 'fields')
      distant_time_fields.delete('TransactionDate')
      distant_time_fields.delete('TransactionTime')
      distant_time_result = described_class.new(response: distant_time_response, provider: :fixture).call

      aggregate_failures do
        expect(structured_result.dig(:candidates, :purchased_at_text)).to eq('2026-05-20 18:42')
        expect(date_only_result.dig(:candidates, :purchased_at_text)).to eq('2026-05-20')
        expect(time_only_result.dig(:candidates, :purchased_at_text)).to eq('18:42')
        expect(line_fallback_result.dig(:candidates, :purchased_at_text)).to eq('2026年05月20日 18:42')
        expect(nearby_fallback_result.dig(:candidates, :purchased_at_text)).to eq('2026年05月20日 18:42')
        expect(fallback_date_only_result.dig(:candidates, :purchased_at_text)).to eq('2026年05月20日')
        expect(fallback_time_only_result.dig(:candidates, :purchased_at_text)).to eq('18:42')
        expect(noisy_fallback_result.dig(:candidates, :purchased_at_text)).to eq('2026年05月20日 18:42')
        expect(distant_time_result.dig(:candidates, :purchased_at_text)).to eq('2026年05月20日')
      end
    end

    it 'お預かり/お釣りだけではpayment_method_textへ昇格しない' do
      fixture_response = JSON.parse(Rails.root.join('spec/fixtures/ocr/parser_boundary_receipt.json').read)
      fixture_response['analyzeResult']['content'] = <<~TEXT
        OCR境界ストア
        合計
        ¥1,900
        お預かり
        ¥2,000
        お釣り
        ¥100
      TEXT
      fixture_response.dig('analyzeResult', 'documents', 0, 'fields').delete('Payments')

      result = described_class.new(response: fixture_response, provider: :fixture).call

      aggregate_failures do
        expect(result.dig(:candidates, :payment_method_text)).to be_nil
        expect(result.dig(:candidates, :total_amount)).to eq(1_900)
        expect(result.dig(:candidates, :adjustment_candidates)).to eq([])
      end
    end

    it '精算・ポイント・クーポン・支払時割引系の行をpayment_method_textへ昇格しない' do
      fixture_response = JSON.parse(Rails.root.join('spec/fixtures/ocr/parser_boundary_receipt.json').read)
      parse_line = lambda do |line|
        response = fixture_response.deep_dup
        response['analyzeResult']['content'] = <<~TEXT
          OCR境界ストア
          合計
          ¥1,900
          #{line}
        TEXT
        response.dig('analyzeResult', 'documents', 0, 'fields').delete('Payments')

        described_class.new(response: response, provider: :fixture).call
      end

      excluded_lines = [
        'お預かり cash 2,000',
        'お釣り cash 100',
        'change cash 100',
        'ポイント利用 -100',
        'ポイント付与 10P',
        'coupon -100',
        'クーポン値引き -100',
        '支払時割引 -40',
        'キャッシュレス還元額 -50',
        'cashless reward -50',
        'cashless discount -50'
      ]
      accepted_lines = {
        'クレジット支払 ¥1,900' => 'クレジット',
        '現金' => '現金',
        '電子マネー決済' => '電子マネー',
        'QR決済' => 'qr決済'
      }

      aggregate_failures do
        excluded_lines.each do |line|
          expect(parse_line.call(line).dig(:candidates, :payment_method_text)).to be_nil, line
        end

        accepted_lines.each do |line, expected|
          expect(parse_line.call(line).dig(:candidates, :payment_method_text)).to eq(expected), line
        end
      end
    end

    it '支払方法行だけではadjustment candidateにしない' do
      fixture_response = JSON.parse(Rails.root.join('spec/fixtures/ocr/parser_boundary_receipt.json').read)
      fixture_response['analyzeResult']['content'] = <<~TEXT
        OCR境界ストア
        合計
        ¥1,900
        クレジット支払 ¥1,900
      TEXT

      result = described_class.new(response: fixture_response, provider: :fixture).call

      aggregate_failures do
        expect(result.dig(:candidates, :payment_method_text)).to eq('クレジット')
        expect(result.dig(:candidates, :adjustment_candidates)).to eq([])
      end
    end

    it '税詳細の対象額・税額行をadjustment candidateにしない' do
      fixture_response = JSON.parse(Rails.root.join('spec/fixtures/ocr/parser_boundary_receipt.json').read)
      fixture_response['analyzeResult']['content'] = <<~TEXT
        OCR境界ストア
        合計
        ¥1,298
        (10%税込対象額
        ¥1,298)
        (10%税額
        ¥118)
        QUICPay
        ¥1,298
      TEXT

      result = described_class.new(response: fixture_response, provider: :fixture).call

      expect(result.dig(:candidates, :adjustment_candidates)).to eq([])
    end

    it '明細化済みのレジ袋数量をadjustment amountとして扱わない' do
      fixture_response = raw_response.deep_dup
      fixture_response['analyzeResult']['content'] = <<~TEXT
        領 収 書
        具たっぷりサラダ巻
        *298
        レジ袋中1枚
        3
        小 計(税抜10%)
        ¥3
        合計
        ¥3
      TEXT
      fields = fixture_response.dig('analyzeResult', 'documents', 0, 'fields')
      fields['Items'] = {
        'valueArray' => [
          {
            'valueObject' => {
              'Description' => { 'valueString' => 'レジ袋中1枚' },
              'TotalPrice' => { 'valueCurrency' => { 'amount' => 3, 'currencyCode' => 'JPY' } }
            }
          }
        ]
      }

      result = described_class.new(response: fixture_response, provider: :fixture).call

      aggregate_failures do
        expect(result.dig(:candidates, :items)).to include(hash_including(raw_text: 'レジ袋中1枚', line_total: 3))
        expect(result.dig(:candidates, :adjustment_candidates)).to eq([])
      end
    end

    it '数量つきレジ袋行と近傍の裸数値だけではadjustment candidateにしない' do
      fixture_response = raw_response.deep_dup
      fixture_response['analyzeResult']['content'] = <<~TEXT
        領 収 書
        レジ袋中1枚
        3
        合計
        ¥3
      TEXT
      fixture_response.dig('analyzeResult', 'documents', 0, 'fields').delete('Items')

      result = described_class.new(response: fixture_response, provider: :fixture).call

      expect(result.dig(:candidates, :adjustment_candidates)).to eq([])
    end

    it '明細化済みのレジ袋行に金額が同一行表示されてもadjustment candidateにしない' do
      fixture_response = raw_response.deep_dup
      fixture_response['analyzeResult']['content'] = <<~TEXT
        領 収 書
        レジ袋中1枚 3円
        合計
        ¥3
      TEXT
      fields = fixture_response.dig('analyzeResult', 'documents', 0, 'fields')
      fields['Items'] = {
        'valueArray' => [
          {
            'valueObject' => {
              'Description' => { 'valueString' => 'レジ袋中1枚' },
              'TotalPrice' => { 'valueCurrency' => { 'amount' => 3, 'currencyCode' => 'JPY' } }
            }
          }
        ]
      }

      result = described_class.new(response: fixture_response, provider: :fixture).call

      aggregate_failures do
        expect(result.dig(:candidates, :items)).to include(hash_including(raw_text: 'レジ袋中1枚', line_total: 3))
        expect(result.dig(:candidates, :adjustment_candidates)).to eq([])
      end
    end

    it '明示的な袋代は引き続きbag_fee adjustment candidateにする' do
      fixture_response = raw_response.deep_dup
      fixture_response['analyzeResult']['content'] = <<~TEXT
        OCR境界ストア
        商品A
        ¥1,000
        袋代 ¥10
        合計
        ¥1,010
      TEXT

      result = described_class.new(response: fixture_response, provider: :fixture).call

      expect(result.dig(:candidates, :adjustment_candidates)).to include(
        hash_including(source_text: '袋代 ¥10', amount: 10, sign_hint: 'surcharge', candidate_reason: 'label_same_line_amount')
      )
    end

    it '日本語の支払時割引はsigned amountがある場合だけadjustment candidateにする' do
      fixture_response = JSON.parse(Rails.root.join('spec/fixtures/ocr/parser_boundary_receipt.json').read)
      fixture_response['analyzeResult']['content'] = <<~TEXT
        OCR境界ストア
        小計
        ¥2,000
        支払時割引 -40
        決済割引
        -30
        合計
        ¥1,930
      TEXT

      result = described_class.new(response: fixture_response, provider: :fixture).call
      adjustment_candidates = result.dig(:candidates, :adjustment_candidates)

      expect(adjustment_candidates).to include(
        hash_including(
          source_text: '支払時割引 -40',
          amount: 40,
          sign_hint: 'discount',
          candidate_reason: 'label_same_line_amount'
        ),
        hash_including(
          source_text: '決済割引',
          amount: 30,
          sign_hint: 'discount',
          candidate_reason: 'signed_amount_neighbor_label'
        )
      )
    end

    it 'ポイント利用はsigned amountがある場合だけpayment adjustment candidateにする' do
      fixture_response = JSON.parse(Rails.root.join('spec/fixtures/ocr/parser_boundary_receipt.json').read)
      fixture_response['analyzeResult']['content'] = <<~TEXT
        OCR境界ストア
        小計
        ¥1,000
        ポイント利用 -100
        ポイント支払 ▲100
        point usage -100
        ポイント付与 10P
        獲得予定ポイント 20P
        保有ポイント 300P
        利用可能ポイント 200P
        クレジット支払 ¥700
        お預かり
        ¥1,000
        お釣り
        ¥300
        合計 ¥900
      TEXT
      fixture_response.dig('analyzeResult', 'documents', 0, 'fields').delete('Total')

      result = described_class.new(response: fixture_response, provider: :fixture).call
      adjustment_candidates = result.dig(:candidates, :adjustment_candidates)
      source_texts = adjustment_candidates.map { |candidate| candidate[:source_text] }

      aggregate_failures do
        expect(adjustment_candidates).to include(
          hash_including(source_text: 'ポイント利用 -100', amount: 100, sign_hint: 'discount', candidate_reason: 'label_same_line_amount'),
          hash_including(source_text: 'ポイント支払 ▲100', amount: 100, sign_hint: 'discount', candidate_reason: 'label_same_line_amount'),
          hash_including(source_text: 'point usage -100', amount: 100, sign_hint: 'discount', candidate_reason: 'label_same_line_amount')
        )
        expect(source_texts).not_to include(
          'ポイント付与 10P',
          '獲得予定ポイント 20P',
          '保有ポイント 300P',
          '利用可能ポイント 200P',
          'クレジット支払 ¥700',
          'お預かり',
          'お釣り'
        )
        expect(result.dig(:candidates, :total_amount)).to eq(900)
      end
    end

    it 'point/coupon/cashless/payment discountを含むOCR境界fixtureのadjustment候補を固定する' do
      fixture_response = JSON.parse(Rails.root.join('spec/fixtures/ocr/parser_boundary_receipt.json').read)

      result = described_class.new(response: fixture_response, provider: :fixture).call
      candidates = result[:candidates]
      adjustment_candidates = candidates[:adjustment_candidates]

      aggregate_failures do
        expect(candidates[:payment_method_text]).to eq('クレジット')
        expect(candidates[:payments]).to contain_exactly(hash_including(method: 'CreditCard', amount: 1_510))
        expect(candidates[:total_amount]).to eq(1_900)
        expect(candidates[:subtotal_amount]).to eq(2_000)
        expect(candidates[:tax_amount]).to eq(154)
        expect(candidates[:tax_details]).to contain_exactly(
          hash_including(description: '8%消費税等', rate: 8, net_amount: 1_080, amount: 80),
          hash_including(description: '10%消費税等', rate: 10, net_amount: 820, amount: 74)
        )
        expect(adjustment_candidates).to include(
          hash_including(
            source_text: 'ポイント利用',
            amount: 300,
            sign_hint: 'discount',
            candidate_reason: 'signed_amount_neighbor_label'
          ),
          hash_including(
            source_text: 'クーポン値引き',
            amount: 100,
            sign_hint: 'discount',
            tax_rate_hint: BigDecimal('0.08'),
            candidate_reason: 'label_signed_neighbor_amount'
          ),
          hash_including(
            source_text: 'キャッシュレス還元額 -50',
            amount: 50,
            sign_hint: 'discount',
            candidate_reason: 'label_same_line_amount'
          ),
          hash_including(
            source_text: 'payment discount -40',
            amount: 40,
            sign_hint: 'discount',
            candidate_reason: 'label_same_line_amount'
          )
        )
      end
    end

    it 'Azure Totalがお預かり金額を指す場合は会計合計候補を優先する' do
      deposit_response = raw_response.deep_dup
      deposit_response['analyzeResult']['content'] = <<~TEXT
        預かりストア
        商品A 1102
        商品B 1102
        小計 2204
        合計 2,204
        お預かり 5,000
        お釣り 2,796
      TEXT
      fields = deposit_response.dig('analyzeResult', 'documents', 0, 'fields')
      fields['Total'] = { 'valueCurrency' => { 'amount' => 5000 } }
      fields['Subtotal'] = { 'valueCurrency' => { 'amount' => 2204 } }
      fields.delete('TotalTax')

      result = described_class.new(response: deposit_response).call

      aggregate_failures do
        expect(result[:success]).to eq(true)
        expect(result.dig(:candidates, :total_amount)).to eq(2_204)
        expect(result.dig(:candidates, :total_amount)).not_to eq(5_000)
      end
    end

    it '割引行を直前itemへ紐付けて割引後line_totalを返す' do
      discount_response = raw_response.deep_dup
      discount_response['analyzeResult']['content'] = <<~TEXT
        割引ストア
        対象商品
        600
        割引
        -300
        合計 300
      TEXT
      fields = discount_response.dig('analyzeResult', 'documents', 0, 'fields')
      fields['Total'] = { 'valueCurrency' => { 'amount' => 300 } }
      fields['Items'] = {
        'valueArray' => [
          {
            'valueObject' => {
              'Description' => { 'valueString' => '対象商品' },
              'Quantity' => { 'valueNumber' => 2 },
              'TotalPrice' => { 'valueCurrency' => { 'amount' => 600 } }
            },
            'confidence' => 0.98
          }
        ]
      }

      result = described_class.new(response: discount_response).call
      item = result.dig(:candidates, :items).first

      aggregate_failures do
        expect(item[:original_line_total]).to eq(600)
        expect(item[:discount_amount]).to eq(300)
        expect(item[:line_total]).to eq(300)
      end
    end

    it '長いレシートfixtureの抽出結果を維持する' do
      fixture_response = JSON.parse(Rails.root.join('spec/fixtures/ocr/long_receipt.json').read)

      result = described_class.new(response: fixture_response, provider: :fixture).call
      candidates = result[:candidates]

      aggregate_failures do
        expect(result[:success]).to eq(true)
        expect(result[:lines].size).to eq(139)
        expect(candidates[:store_name]).to eq('くらしのパートナー みどりスーパー 新宿南口店')
        expect(candidates[:total_amount]).to eq(8_808)
        expect(candidates[:subtotal_amount]).to eq(8_156)
        expect(candidates[:tax_amount]).to eq(652)
        expect(candidates[:tax_rate]).to eq(0.08)
        expect(candidates[:payment_method_text]).to eq('quicpay')
        expect(candidates[:items].size).to eq(33)
        expect(candidates[:items].first).to include(
          raw_text: '香ばしバターロール6個入(マーガリン)',
          line_total: 178,
          original_line_total: 178,
          confidence: 0.925
        )
        expect(candidates[:tax_details]).to include(
          hash_including(description: '外税額', amount: 652, rate: 0.08, net_amount: 8_156)
        )
      end
    end

    it '主要な支払方法の表記揺れをOCR行からpayment_method_textへ抽出する' do
      cases = {
        '交通系IC支払' => '交通系ic',
        '電子マネー決済' => '電子マネー',
        'タッチ決済' => 'タッチ決済',
        'contactless payment' => 'contactless',
        'mobile payment' => 'mobilepayment',
        'Apple Pay' => 'applepay',
        'Google Pay' => 'googlepay',
        'QR決済' => 'qr決済',
        'Union Pay' => 'unionpay',
        'Master Card' => 'mastercard',
        'Debit Card' => 'debit'
      }

      aggregate_failures do
        cases.each do |line, expected|
          response = raw_response.deep_dup
          response['analyzeResult']['content'] = <<~TEXT
            サンプルストア
            合計 1280
            #{line}
          TEXT
          response.dig('analyzeResult', 'documents', 0, 'fields').delete('Payments')

          result = described_class.new(response: response).call

          expect(result.dig(:candidates, :payment_method_text)).to eq(expected), line
        end
      end
    end

    it '広告や対応ブランド一覧だけではpayment_method_textへ昇格しない' do
      response = raw_response.deep_dup
      response['analyzeResult']['content'] = <<~TEXT
        サンプルストア
        PayPay使えます
        電子マネー対応
        各種クレジット取扱
        合計 1280
      TEXT
      response.dig('analyzeResult', 'documents', 0, 'fields').delete('Payments')

      result = described_class.new(response: response).call

      expect(result.dig(:candidates, :payment_method_text)).to be_nil
    end

    it '1画像内の複数レシート疑いをpolygonクラスタから検知する' do
      fixture_response = JSON.parse(Rails.root.join('spec/fixtures/ocr/multi_receipts_in_one_image.json').read)

      result = described_class.new(response: fixture_response, provider: :fixture).call

      aggregate_failures do
        expect(fixture_response.dig('analyzeResult', 'documents').size).to eq(1)
        expect(fixture_response.dig('analyzeResult', 'pages').size).to eq(1)
        expect(fixture_response.dig('analyzeResult', 'documents', 0, 'confidence')).to be > 0.98
        expect(result.dig(:candidates, :review_reasons)).to include('multiple_receipts_suspected')
      end
    end

    it '単体レシートfixturesでは複数レシート疑いを付けない' do
      fixture_names = %w[
        single_tax_receipt
        long_receipt
        rotated_receipt
        blurred_receipt
      ]

      fixture_names.each do |fixture_name|
        fixture_response = JSON.parse(Rails.root.join("spec/fixtures/ocr/#{fixture_name}.json").read)
        result = described_class.new(response: fixture_response, provider: :fixture).call

        aggregate_failures(fixture_name) do
          expect(result[:success]).to eq(true)
          expect(result.dig(:candidates, :review_reasons)).not_to include('multiple_receipts_suspected')
        end
      end
    end

    it '割引の多いfixtureの割引情報を維持する' do
      fixture_response = JSON.parse(Rails.root.join('spec/fixtures/ocr/discount_heavy_receipt.json').read)

      result = described_class.new(response: fixture_response, provider: :fixture).call
      discounted_items = result.dig(:candidates, :items).select { |item| item[:discount_amount].present? }

      aggregate_failures do
        expect(result[:success]).to eq(true)
        expect(result.dig(:candidates, :payment_method_text)).to eq('クレジット')
        expect(result.dig(:candidates, :tax_amount)).to eq(42)
        expect(discounted_items).to include(
          hash_including(
            raw_text: '国産豚こま切れ肉 200g',
            original_line_total: 398,
            discount_amount: 50,
            discount_rate: nil,
            line_total: 348
          )
        )
        expect(discounted_items).to include(
          hash_including(
            raw_text: 'たまご Mサイズ 6個入',
            original_line_total: 128,
            discount_amount: 30,
            discount_rate: nil,
            line_total: 98
          )
        )
        expect(result.dig(:candidates, :items).map { |item| item[:raw_text] }).not_to include('夜間割引(20%)')
      end
    end

    it '複数税率fixtureではitem税率と税率別対象額をOCR行から補完する' do
      fixture_response = JSON.parse(Rails.root.join('spec/fixtures/ocr/multiple_tax_receipt.json').read)

      result = described_class.new(response: fixture_response, provider: :fixture).call
      candidates = result[:candidates]

      aggregate_failures do
        expect(candidates[:items].map { |item| item[:tax_rate] }).to eq([
          BigDecimal('0.08'),
          BigDecimal('0.08'),
          BigDecimal('0.08'),
          BigDecimal('0.1'),
          BigDecimal('0.1'),
          BigDecimal('0.1')
        ])
        expect(candidates[:tax_details]).to contain_exactly(
          hash_including(rate: 0.08, net_amount: 604, amount: 44),
          hash_including(rate: 0.1, net_amount: 994, amount: 90)
        )
      end
    end

    it '税率別対象額と税合計だけがOCR行にある内税レシートからTaxDetailsを復元する' do
      response = raw_response.deep_dup
      response['analyzeResult']['content'] = <<~TEXT
        SampleMart
        中央南三丁目店
        商品A
        ¥151軽
        商品B
        ¥178軽
        商品C
        ¥155
        商品D
        ¥360
        合 計
        ¥844
        (10%対象
        ¥515)
        ( 8%対象
        ¥329)
        (内消費税等
        ¥70)
      TEXT
      fields = response['analyzeResult']['documents'].first['fields']
      fields['MerchantName'] = { 'valueString' => '中央南三丁目店' }
      fields['Total'] = { 'valueCurrency' => { 'amount' => 844, 'currencyCode' => 'JPY' } }
      fields['Subtotal'] = nil
      fields['TotalTax'] = { 'valueCurrency' => { 'amount' => 70, 'currencyCode' => 'JPY' } }
      fields['TaxDetails'] = {
        'valueArray' => [
          {
            'valueObject' => {
              'Description' => { 'valueString' => '内消費税等' },
              'Amount' => { 'valueCurrency' => { 'amount' => 70, 'currencyCode' => 'JPY' } }
            }
          }
        ]
      }

      result = described_class.new(response: response, provider: :fixture).call

      aggregate_failures do
        # 検算: 329 * 8 / 108 = 24.37... floor 24, net 305。
        # 検算: 515 * 10 / 110 = 46.81... floor 46, net 469。税額合計は 24 + 46 = 70。
        expect(result.dig(:candidates, :tax_details)).to contain_exactly(
          hash_including(description: '8%対象', rate: 0.08, net_amount: 305, amount: 24),
          hash_including(description: '10%対象', rate: 0.1, net_amount: 469, amount: 46)
        )
      end
    end

    it '税額0円の小額10%対象が印字されていても複数税率TaxDetailsとして保持する' do
      response = raw_response.deep_dup
      response['analyzeResult']['content'] = <<~TEXT
        SampleMart
        商品A
        ¥798軽
        レジ袋
        ¥3
        合 計
        ¥801
        小 計 (税抜8%)
        ¥739
        消費税等 (8%)
        ¥59
        小 計 (税抜10%)
        ¥3
        (税率8%対象
        ¥798)
        (税率10%対象
        ¥3)
        Suica支払
        ¥801
      TEXT
      fields = response['analyzeResult']['documents'].first['fields']
      fields['MerchantName'] = { 'valueString' => 'SampleMart' }
      fields['Total'] = { 'valueCurrency' => { 'amount' => 801, 'currencyCode' => 'JPY' } }
      fields['Subtotal'] = nil
      fields['TotalTax'] = { 'valueCurrency' => { 'amount' => 59, 'currencyCode' => 'JPY' } }
      fields['TaxDetails'] = {
        'valueArray' => [
          {
            'valueObject' => {
              'Description' => { 'valueString' => '消費税等' },
              'Amount' => { 'valueCurrency' => { 'amount' => 59, 'currencyCode' => 'JPY' } },
              'Rate' => { 'valueNumber' => 8 },
              'NetAmount' => { 'valueCurrency' => { 'amount' => 739, 'currencyCode' => 'JPY' } }
            }
          }
        ]
      }

      result = described_class.new(response: response, provider: :fixture).call

      aggregate_failures do
        # 検算: 739 * 8% = 59.12 -> floor 59, gross 798。
        # 検算: 3 * 10% = 0.3 -> floor 0, gross 3。税額合計は 59。
        expect(result.dig(:candidates, :tax_details)).to contain_exactly(
          hash_including(description: include('税抜8%'), rate: 0.08, net_amount: 739, amount: 59),
          hash_including(description: include('税抜10%'), rate: 0.1, net_amount: 3, amount: 0)
        )
      end
    end

    it '単一税率でも対象計と内税額が合計に一致する場合はTaxDetailsを復元する' do
      response = raw_response.deep_dup
      response['analyzeResult']['content'] = <<~TEXT
        サンプルリア
        みどりモール店
        海星サラダ
        ¥350
        ピリカラチキン
        ¥300
        合計
        ¥3,130
        10%対象計
        ¥3,130
        (内税額
        ¥284)
        クレジット
        ¥3,130
      TEXT
      fields = response['analyzeResult']['documents'].first['fields']
      fields['MerchantName'] = { 'valueString' => 'サンプルリア' }
      fields['Total'] = { 'valueCurrency' => { 'amount' => 3130, 'currencyCode' => 'JPY' } }
      fields['Subtotal'] = nil
      fields['TotalTax'] = { 'valueCurrency' => { 'amount' => 284, 'currencyCode' => 'JPY' } }
      fields['TaxDetails'] = {
        'valueArray' => [
          {
            'valueObject' => {
              'Description' => { 'valueString' => '内税額' },
              'Amount' => { 'valueCurrency' => { 'amount' => 284, 'currencyCode' => 'JPY' } }
            }
          }
        ]
      }

      result = described_class.new(response: response, provider: :fixture).call

      aggregate_failures do
        expect(result.dig(:candidates, :tax_details)).to contain_exactly(
          hash_including(description: '10%対象', rate: 0.1, net_amount: 2846, amount: 284)
        )
      end
    end

    it 'TaxDetails descriptionが汎用語でも周辺OCR行から税抜小計/税込対象の文脈を保持する' do
      response = raw_response.deep_dup
      response['analyzeResult']['content'] = <<~TEXT
        小 計 (税抜10%)
        ¥300
        消費税等 (10%)
        ¥30
        (税率10%対象
        ¥820)
        (内消費税等10%
        ¥74)
      TEXT
      response['analyzeResult']['documents'].first['fields']['TaxDetails'] = {
        'valueArray' => [
          {
            'valueObject' => {
              'Description' => { 'valueString' => '消費税等' },
              'Amount' => { 'valueCurrency' => { 'amount' => 30, 'currencyCode' => 'JPY' } },
              'Rate' => { 'valueNumber' => 10 },
              'NetAmount' => { 'valueCurrency' => { 'amount' => 300, 'currencyCode' => 'JPY' } }
            }
          },
          {
            'valueObject' => {
              'Description' => { 'valueString' => '内消費税等' },
              'Amount' => { 'valueCurrency' => { 'amount' => 74, 'currencyCode' => 'JPY' } },
              'Rate' => { 'valueNumber' => 10 },
              'NetAmount' => { 'valueCurrency' => { 'amount' => 820, 'currencyCode' => 'JPY' } }
            }
          }
        ]
      }

      result = described_class.new(response: response, provider: :fixture).call

      aggregate_failures do
        expect(result.dig(:candidates, :tax_details)).to include(
          hash_including(
            net_amount: 300,
            amount: 30,
            description: include('小 計 (税抜10%)', '消費税等')
          ),
          hash_including(
            net_amount: 820,
            amount: 74,
            description: include('(税率10%対象', '(内消費税等10%')
          )
        )
      end
    end

    it '単一内税fixtureでは対象額をTaxDetails net_amountへ推定しない' do
      fixture_response = JSON.parse(Rails.root.join('spec/fixtures/ocr/single_tax_receipt.json').read)

      result = described_class.new(response: fixture_response, provider: :fixture).call

      aggregate_failures do
        expect(result.dig(:candidates, :tax_details)).to include(
          hash_including(rate: 0.1, amount: 70, net_amount: nil)
        )
        expect(result.dig(:candidates, :items).map { |item| item[:tax_rate] }).to all(be_nil)
      end
    end

    it '完全なMerchantNameがあるfixtureでは先頭商品名より店舗名を優先する' do
      expectations = {
        'return_receipt' => 'ライフスマイルマーケット 渋谷店',
        'delivery_and_bag_fee_receipt' => 'スマイルデリバリー 東京中央店',
        'service_and_late_night_receipt' => 'ナイトダイニング 月灯り 新宿店'
      }

      expectations.each do |fixture_name, expected_store_name|
        fixture_response = JSON.parse(Rails.root.join("spec/fixtures/ocr/#{fixture_name}.json").read)

        result = described_class.new(response: fixture_response, provider: :fixture).call

        expect(result.dig(:candidates, :store_name)).to eq(expected_store_name)
      end
    end

    it '指定管理者近傍の法人MerchantNameより上部の顧客向け施設名を優先する' do
      response = raw_response.deep_dup
      response['analyzeResult']['content'] = <<~TEXT
        サンプル公園
        駐車場
        領収書
        登録番号:t7490001001867
        東京都中央区銀座1-1-1
        駐車券自家用車等 ¥500
        現 計 ¥500
        サンプル公園指定管理者
        株式会社
        サンプル管理
      TEXT
      response['analyzeResult']['documents'][0]['fields']['MerchantName'] = {
        'valueString' => "株式会社\nサンプル管理",
        'confidence' => 0.972
      }

      result = described_class.new(response: response, provider: :fixture).call

      # 上部見出し2行を結合し、下部の指定管理者法人名より優先する:
      # 「サンプル公園」 + 「駐車場」 = 「サンプル公園駐車場」
      expect(result.dig(:candidates, :store_name)).to eq('サンプル公園駐車場')
    end

    it '法人名が唯一の上部店舗名ならMerchantNameを維持する' do
      response = raw_response.deep_dup
      response['analyzeResult']['content'] = <<~TEXT
        ABC Stores Inc.
        Receipt
        Coffee $4.00
        Total $4.00
      TEXT
      response['analyzeResult']['documents'][0]['fields']['MerchantName'] = {
        'valueString' => 'ABC Stores Inc.',
        'confidence' => 0.95
      }

      result = described_class.new(response: response, provider: :fixture).call

      expect(result.dig(:candidates, :store_name)).to eq('ABC Stores Inc.')
    end

    it 'ブランド名と印字された場所名を結合し、未印字のsuffixは追加しない' do
      response = raw_response.deep_dup
      response['analyzeResult']['content'] = <<~TEXT
        サンプル食堂
        株式会社サンプル食堂
        サンプル通り
        東京都渋谷区道玄坂1-2-3
        お客様相談室 0120-498-007
        登録番号:t2010401093920
        合計 ¥1,510
      TEXT
      response['analyzeResult']['documents'][0]['fields']['MerchantName'] = {
        'valueString' => 'サンプル食堂',
        'confidence' => 0.95
      }

      result = described_class.new(response: response, provider: :fixture).call

      expect(result.dig(:candidates, :store_name)).to eq('サンプル食堂 サンプル通り')
    end

    it 'managed by近傍の海外法人MerchantNameより上部の施設名を優先する' do
      response = raw_response.deep_dup
      response['analyzeResult']['content'] = <<~TEXT
        Harbor Parking
        North Garage
        Receipt
        Parking fee $12.00
        Total $12.00
        Managed by
        Harima House Ltd.
      TEXT
      response['analyzeResult']['documents'][0]['fields']['MerchantName'] = {
        'valueString' => 'Harima House Ltd.',
        'confidence' => 0.94
      }

      result = described_class.new(response: response, provider: :fixture).call

      expect(result.dig(:candidates, :store_name)).to eq('harbor parking north garage')
    end

    it 'discount_heavy_receiptでは商品単位値引きを対象商品へ紐付け、レシート単位値引きを明細化しない' do
      fixture_response = JSON.parse(Rails.root.join('spec/fixtures/ocr/discount_heavy_receipt.json').read)

      result = described_class.new(response: fixture_response, provider: :fixture).call
      items = result.dig(:candidates, :items)

      aggregate_failures do
        expect(items.map { |item| item[:raw_text] }).to eq([
          '国産豚こま切れ肉 200g',
          'きゅうり 1本',
          "トマト (大玉)\n1個",
          'たまご Mサイズ 6個入'
        ])
        expect(items.map { |item| item.slice(:line_total, :original_line_total, :discount_amount) }).to eq([
          { line_total: 348, original_line_total: 398, discount_amount: 50 },
          { line_total: 258, original_line_total: 258, discount_amount: nil },
          { line_total: 198, original_line_total: 198, discount_amount: nil },
          { line_total: 98, original_line_total: 128, discount_amount: 30 }
        ])
        expect(result.dig(:candidates, :adjustment_candidates).map { |candidate| candidate[:amount] }).to contain_exactly(100, 200, 31)
      end
    end

    it '特殊加減算fixtureからOCR adjustment candidatesを抽出する' do
      expectations = {
        'return_receipt' => [
          { source_text: '返品(液体洗剤)', amount: 980, sign_hint: 'discount', candidate_reason: 'label_signed_neighbor_amount' }
        ],
        'delivery_and_bag_fee_receipt' => [
          { source_text: 'レジ袋代', amount: 10, sign_hint: 'surcharge', candidate_reason: 'label_next_amount' },
          { source_text: '配送料', amount: 550, sign_hint: 'surcharge', candidate_reason: 'label_next_amount' }
        ],
        'service_and_late_night_receipt' => [
          { source_text: 'サービス料10%', amount: 486, sign_hint: 'surcharge', tax_rate_hint: BigDecimal('0.1') },
          { source_text: '深夜料金10%', amount: 486, sign_hint: 'surcharge', tax_rate_hint: BigDecimal('0.1') }
        ]
      }

      expectations.each do |fixture_name, expected_candidates|
        fixture_response = JSON.parse(Rails.root.join("spec/fixtures/ocr/#{fixture_name}.json").read)
        result = described_class.new(response: fixture_response, provider: :fixture).call
        candidates = result.dig(:candidates, :adjustment_candidates)

        aggregate_failures(fixture_name) do
          expect(candidates).to include(*expected_candidates.map { |candidate| hash_including(candidate) })
          expect(candidates).to all(include(needs_review: true))
          expect(candidates).to all(include(:source_line_index, :neighboring_texts, :confidence))
        end
      end
    end

    it '通常・税詳細fixtureでは税額や合計行をadjustment candidatesにしない' do
      fixture_names = %w[
        single_tax_receipt
        multiple_tax_receipt
        external_tax_receipt
        long_receipt
        blurred_receipt
        rotated_receipt
      ]

      fixture_names.each do |fixture_name|
        fixture_response = JSON.parse(Rails.root.join("spec/fixtures/ocr/#{fixture_name}.json").read)
        result = described_class.new(response: fixture_response, provider: :fixture).call

        aggregate_failures(fixture_name) do
          expect(result[:success]).to eq(true)
          expect(result.dig(:candidates, :adjustment_candidates)).to eq([])
        end
      end
    end

    it '壊れた配列構造でも payments / tax_details / items は空配列で安全に返す' do
      broken_response = raw_response.deep_dup
      fields = broken_response.dig('analyzeResult', 'documents', 0, 'fields')
      fields['Payments']['valueArray'] = 'invalid'
      fields['TaxDetails']['valueArray'] = { 'bad' => 'shape' }
      fields['Items']['valueArray'] = nil

      result = described_class.new(response: broken_response).call
      candidates = result[:candidates]

      aggregate_failures do
        expect(result[:success]).to eq(true)
        expect(candidates[:payments]).to eq([])
        expect(candidates[:tax_details]).to eq([])
        expect(candidates[:items]).to eq([])
      end
    end

    it 'CountryRegionは3文字uppercase形式へ正規化する' do
      response = raw_response.deep_dup
      fields = response.dig('analyzeResult', 'documents', 0, 'fields')
      fields['CountryRegion'] = { 'valueCountryRegion' => ' jpn ' }

      result = described_class.new(response: response).call

      expect(result.dig(:candidates, :country_region)).to eq('JPN')
    end

    it 'CountryRegion confidenceは現行parser contractに含めずcountry codeのみを返す' do
      response = raw_response.deep_dup
      fields = response.dig('analyzeResult', 'documents', 0, 'fields')
      fields['CountryRegion'] = { 'valueCountryRegion' => ' usa ', 'confidence' => 0.1 }

      result = described_class.new(response: response).call

      aggregate_failures do
        expect(result.dig(:candidates, :country_region)).to eq('USA')
        expect(result.dig(:candidates, :confidence_summary)).not_to have_key(:country_region)
      end
    end

    it '壊れたJSON文字列では ocr_api_error を返す' do
      result = described_class.new(response: '{invalid json}', provider: 'azure_document_intelligence').call

      aggregate_failures do
        expect(result[:success]).to eq(false)
        expect(result[:error_code]).to eq('ocr_api_error')
        expect(result[:raw_text]).to eq('')
        expect(result[:lines]).to eq([])
        expect(result.dig(:meta, :provider)).to eq('azure_document_intelligence')
      end
    end

    it '不正なAzureレスポンスでもRecify内部のpolling metricsは維持する' do
      response = {
        'status' => 'succeeded',
        Ocr::Client::POLLING_METRICS_KEY => {
          'poll_count' => 2,
          'final_status' => 'succeeded',
          'reached_max_poll' => false
        }
      }

      result = described_class.new(response: response, provider: 'azure_document_intelligence').call

      aggregate_failures do
        expect(result[:success]).to eq(false)
        expect(result[:error_code]).to eq('ocr_api_error')
        expect(result.dig(:meta, :polling_metrics)).to include(
          poll_count: 2,
          final_status: 'succeeded',
          reached_max_poll: false
        )
      end
    end

    it '不正な入力では統一されたエラー形式を返す' do
      result = described_class.new(response: nil, provider: 'azure_document_intelligence').call

      aggregate_failures do
        expect(result[:success]).to eq(false)
        expect(result[:error_code]).to eq('unexpected_error')
        expect(result[:raw_text]).to eq('')
        expect(result[:lines]).to eq([])
        expect(result[:candidates][:store_name]).to be_nil
        expect(result[:candidates][:store_address]).to be_nil
        expect(result[:candidates][:store_phone_number]).to be_nil
        expect(result[:candidates][:purchased_at_text]).to be_nil
        expect(result[:candidates][:total_amount]).to be_nil
        expect(result[:candidates][:items]).to eq([])
        expect(result[:candidates][:payments]).to eq([])
        expect(result[:candidates][:tax_details]).to eq([])
        expect(result.dig(:meta, :provider)).to eq('azure_document_intelligence')
      end
    end
  end
end
