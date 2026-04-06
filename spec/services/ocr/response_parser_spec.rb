require 'rails_helper'

RSpec.describe Ocr::ResponseParser do
  describe '.call' do
    let(:raw_response) do
      {
        'raw_text' => <<~TEXT,
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
        'lines' => [
          'サンプルストア',
          '東京都渋谷区1-2-3',
          'TEL 03-1234-5678',
          '2026/04/02 12:34',
          'コーヒー 180',
          'サンド 550 x2',
          '小計 1180',
          '消費税 80',
          'チップ 100',
          '合計 1280',
          'Master'
        ],
        'fields' => {
          'MerchantName' => { 'valueString' => 'サンプルストア' },
          'MerchantAddress' => { 'valueString' => '東京都渋谷区1-2-3' },
          'MerchantPhoneNumber' => { 'valueString' => '03-1234-5678' },
          'Subtotal' => { 'valueNumber' => 1180 },
          'TotalTax' => { 'valueNumber' => 80 },
          'Tip' => { 'valueNumber' => 100 },
          'CountryRegion' => { 'valueString' => 'JP' },
          'ReceiptType' => { 'valueString' => 'Meal' },
          'Payments' => {
            'valueArray' => [
              {
                'valueObject' => {
                  'Method' => { 'valueString' => 'CreditCard' },
                  'Amount' => { 'valueNumber' => 1280 }
                }
              }
            ]
          },
          'TaxDetails' => {
            'valueArray' => [
              {
                'valueObject' => {
                  'Description' => { 'valueString' => 'Sales Tax' },
                  'Amount' => { 'valueNumber' => 80 },
                  'Rate' => { 'valueNumber' => 10 },
                  'NetAmount' => { 'valueNumber' => 800 }
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
                  'Price' => { 'valueNumber' => 180 },
                  'TotalPrice' => { 'valueNumber' => 180 },
                  'ProductCode' => { 'valueString' => 'C001' }
                },
                'confidence' => 0.98
              },
              {
                'valueObject' => {
                  'Description' => { 'valueString' => 'サンド' },
                  'Quantity' => { 'valueNumber' => 2 },
                  'QuantityUnit' => { 'valueString' => '個' },
                  'Price' => { 'valueNumber' => 550 },
                  'TotalPrice' => { 'valueNumber' => 1100 },
                  'ProductCode' => { 'valueString' => 'S001' }
                },
                'confidence' => 0.97
              }
            ]
          }
        }
      }
    end

    it 'Azureレスポンスを内部形式へ厳密に変換する' do
      result = described_class.new(response: raw_response).call

      aggregate_failures do
        expect(result[:success]).to eq(true)
        expect(result[:raw_text]).to include('サンプルストア')
        expect(result[:lines]).to include('コーヒー 180', 'サンド 550 x2')
        expect(result[:error_code]).to be_nil
        expect(result[:meta]).to be_a(Hash)
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
        expect(candidates[:purchased_at_text]).to eq('2026/04/02 12:34')
        expect(candidates[:total_amount]).to eq(1280)
        expect(candidates[:subtotal_amount]).to eq(1180)
        expect(candidates[:tax_amount]).to eq(80)
        expect(candidates[:tax_rate]).to eq(10)
        expect(candidates[:tip_amount]).to eq(100)
        expect(candidates[:country_region]).to eq('JP')
        expect(candidates[:receipt_type]).to eq('Meal')
        expect(candidates[:payment_method_text]).to eq('master')
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

    it 'fieldsが一部欠けていても lines から補助抽出できる' do
      partial_response = raw_response.deep_dup
      partial_response['fields'].delete('Subtotal')
      partial_response['fields'].delete('TotalTax')
      partial_response['fields'].delete('MerchantName')
      partial_response['fields'].delete('Items')

      result = described_class.new(response: partial_response).call
      candidates = result[:candidates]

      aggregate_failures do
        expect(candidates[:store_name]).to eq('サンプルストア')
        expect(candidates[:subtotal_amount]).to eq(1180)
        expect(candidates[:tax_amount]).to eq(80)
        expect(candidates[:items]).to eq([])
        expect(result[:success]).to eq(true)
      end
    end

    it '不正な入力では統一されたエラー形式を返す' do
      result = described_class.new(response: nil).call

      aggregate_failures do
        expect(result[:success]).to eq(false)
        expect(result[:error_code]).to be_nil.or be_present
        expect(result[:raw_text]).to eq('')
        expect(result[:lines]).to eq([])
        expect(result[:candidates][:items]).to eq([])
        expect(result[:candidates][:payments]).to eq([])
        expect(result[:candidates][:tax_details]).to eq([])
      end
    end
  end
end
