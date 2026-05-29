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
                'MerchantAddress' => { 'valueString' => '東京都渋谷区1-2-3' },
                'MerchantPhoneNumber' => { 'valueString' => '03-1234-5678' },
                'TransactionDate' => { 'valueDate' => '2026-04-02' },
                'TransactionTime' => { 'valueTime' => '12:34' },
                'Total' => { 'valueCurrency' => { 'amount' => 1280 } },
                'Subtotal' => { 'valueCurrency' => { 'amount' => 1180 } },
                'TotalTax' => { 'valueCurrency' => { 'amount' => 80 } },
                'Tip' => { 'valueCurrency' => { 'amount' => 100 } },
                'CountryRegion' => { 'valueCountryRegion' => 'JPN' },
                'ReceiptType' => { 'valueString' => 'Meal' },
                'Payments' => {
                  'valueArray' => [
                    {
                      'valueObject' => {
                        'Method' => { 'valueString' => 'CreditCard' },
                        'Amount' => { 'valueCurrency' => { 'amount' => 1280 } }
                      }
                    }
                  ]
                },
                'TaxDetails' => {
                  'valueArray' => [
                    {
                      'valueObject' => {
                        'Description' => { 'valueString' => 'Sales Tax' },
                        'Amount' => { 'valueCurrency' => { 'amount' => 80 } },
                        'Rate' => { 'valueNumber' => 10 },
                        'NetAmount' => { 'valueCurrency' => { 'amount' => 800 } }
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
                        'Price' => { 'valueCurrency' => { 'amount' => 180 } },
                        'TotalPrice' => { 'valueCurrency' => { 'amount' => 180 } },
                        'ProductCode' => { 'valueString' => 'C001' }
                      },
                      'confidence' => 0.98
                    },
                    {
                      'valueObject' => {
                        'Description' => { 'valueString' => 'サンド' },
                        'Quantity' => { 'valueNumber' => 2 },
                        'QuantityUnit' => { 'valueString' => '個' },
                        'Price' => { 'valueCurrency' => { 'amount' => 550 } },
                        'TotalPrice' => { 'valueCurrency' => { 'amount' => 1100 } },
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
        expect(candidates[:store_phone_number]).to eq('03-1234-5678')
        expect(candidates[:purchased_at_text]).to eq('2026-04-02 12:34')
        expect(candidates[:total_amount]).to eq(1280)
        expect(candidates[:subtotal_amount]).to eq(1180)
        expect(candidates[:tax_amount]).to eq(80)
        expect(candidates[:tax_rate]).to eq(10)
        expect(candidates[:tip_amount]).to eq(100)
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
        expect(first_item[:quantity_unit]).to eq('杯')
        expect(first_item[:product_code]).to eq('C001')
        expect(first_item[:line_total]).to eq(180)
        expect(first_item[:confidence]).to eq(0.98)

        expect(second_item[:raw_text]).to eq('サンド')
        expect(second_item[:price]).to eq(550)
        expect(second_item[:quantity]).to eq(2)
        expect(second_item[:quantity_unit]).to eq('個')
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
        expect(candidates[:tax_amount]).to eq(8)
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
        expect(discounted_items).to include(
          hash_including(
            raw_text: "たまご Mサイズ 6個入\n国産豚こま切れ肉",
            original_line_total: 128,
            discount_amount: 50,
            discount_rate: nil,
            line_total: 78
          )
        )
        expect(discounted_items).to include(
          hash_including(
            raw_text: '夜間割引(20%)',
            original_line_total: 100,
            discount_amount: 345_909,
            discount_rate: BigDecimal('0.08'),
            line_total: 0
          )
        )
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
