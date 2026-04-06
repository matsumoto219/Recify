require 'rails_helper'

RSpec.describe ReceiptBuildParamsService do
  describe '.call' do
    let(:ocr_result) do
      {
        candidates: {
          store_name: 'サンプルストア',
          store_address: '東京都渋谷区1-2-3',
          store_phone_number: '03-1234-5678',
          purchased_at_text: '2026/04/02 12:34',
          total_amount: 1280,
          subtotal_amount: 1180,
          tax_amount: 80,
          tax_rate: 10,
          tip_amount: 100,
          country_region: 'JP',
          receipt_type: 'Meal',
          payment_method_text: 'Master',
          items: [
            {
              raw_text: 'コーヒー',
              price: 180,
              quantity: 1,
              quantity_unit: '杯',
              product_code: 'C001',
              line_total: 180,
              confidence: 0.98
            },
            {
              raw_text: 'サンド',
              price: 550,
              quantity: 2,
              quantity_unit: '個',
              product_code: 'S001',
              line_total: 1100,
              confidence: 0.97
            }
          ],
          payments: [
            { method: 'CreditCard', amount: 1280 }
          ],
          tax_details: [
            { description: 'Sales Tax', amount: 80, rate: 10, net_amount: 800 }
          ]
        },
        lines: []
      }
    end

    context 'AI結果なしの場合' do
      it 'receipt_attributesが正しく生成される' do
        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          expect(params[:receipt_attributes][:store_name]).to eq('サンプルストア')
          expect(params[:receipt_attributes][:store_address]).to eq('東京都渋谷区1-2-3')
          expect(params[:receipt_attributes][:store_phone_number]).to eq('03-1234-5678')
          expect(params[:receipt_attributes][:total_amount]).to eq(1280)
          expect(params[:receipt_attributes][:subtotal_amount]).to eq(1180)
          expect(params[:receipt_attributes][:tax_amount]).to eq(80)
          expect(params[:receipt_attributes][:tax_rate].to_i).to eq(10)
          expect(params[:receipt_attributes][:tip_amount]).to eq(100)
          expect(params[:receipt_attributes][:country_region]).to eq('JP')
          expect(params[:receipt_attributes][:receipt_type]).to eq('Meal')
          expect(params[:receipt_attributes][:payment_method]).to eq('credit_card')
          expect(params[:receipt_attributes][:purchased_at]).to be_present
        end
      end

      it 'itemsが正しく生成される' do
        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        items = params[:receipt_items_attributes]

        aggregate_failures do
          expect(items.size).to eq(2)
          expect(items.first[:raw_text]).to eq('コーヒー')
          expect(items.first[:quantity_unit]).to eq('杯')
          expect(items.first[:product_code]).to eq('C001')
          expect(items.first[:line_total]).to eq(180)
          expect(items.first[:confidence]).to be_present
          expect(items.second[:raw_text]).to eq('サンド')
          expect(items.second[:quantity]).to eq(2)
          expect(items.second[:quantity_unit]).to eq('個')
          expect(items.second[:product_code]).to eq('S001')
          expect(items.second[:line_total]).to eq(1100)
        end
      end

      it 'paymentsが正しく生成される' do
        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        payments = params[:receipt_payments_attributes]

        aggregate_failures do
          expect(payments.size).to eq(1)
          expect(payments.first[:method]).to eq('CreditCard')
          expect(payments.first[:amount]).to eq(1280)
        end
      end

      it 'tax_detailsが正しく生成される' do
        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        tax = params[:receipt_tax_details_attributes].first

        aggregate_failures do
          expect(params[:receipt_tax_details_attributes].size).to eq(1)
          expect(tax[:description]).to eq('Sales Tax')
          expect(tax[:amount]).to eq(80)
          expect(tax[:rate].to_i).to eq(10)
          expect(tax[:net_amount]).to eq(800)
        end
      end
    end

    context 'AI結果ありの場合' do
      let(:ai_result) do
        {
          receipt_attributes: {
            store_name: 'AI補正ストア',
            payment_method: 'qr_payment'
          },
          receipt_items_attributes: [
            {
              raw_text: 'コーヒー',
              suggested_name: 'ブレンドコーヒー',
              category: 'drink',
              needs_review: false
            },
            {
              raw_text: 'サンド',
              suggested_name: 'たまごサンド',
              category: 'food',
              needs_review: true
            }
          ]
        }
      end

      it 'AI補完結果で上書きしつつAzureの確定値を保持する' do
        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)

        aggregate_failures do
          expect(params[:receipt_attributes][:store_name]).to eq('AI補正ストア')
          expect(params[:receipt_attributes][:payment_method]).to eq('qr_payment')
          expect(params[:receipt_attributes][:tip_amount]).to eq(100)
          expect(params[:receipt_attributes][:country_region]).to eq('JP')
          expect(params[:receipt_attributes][:receipt_type]).to eq('Meal')
        end
      end

      it 'AI補完で明細名とカテゴリを上書きしてもAzure由来のquantity_unitとproduct_codeを保持する' do
        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)

        first_item = params[:receipt_items_attributes].first
        second_item = params[:receipt_items_attributes].second

        aggregate_failures do
          expect(first_item[:suggested_name]).to eq('ブレンドコーヒー')
          expect(first_item[:category]).to eq('drink')
          expect(first_item[:quantity_unit]).to eq('杯')
          expect(first_item[:product_code]).to eq('C001')
          expect(first_item[:needs_review]).to eq(false)

          expect(second_item[:suggested_name]).to eq('たまごサンド')
          expect(second_item[:category]).to eq('food')
          expect(second_item[:quantity_unit]).to eq('個')
          expect(second_item[:product_code]).to eq('S001')
          expect(second_item[:needs_review]).to eq(true)
        end
      end
    end

    context 'OCR itemsが空の場合' do
      let(:ocr_result) do
        {
          candidates: {
            store_name: 'サンプルストア',
            total_amount: 1280,
            payment_method_text: '現金',
            items: [],
            payments: [],
            tax_details: []
          },
          lines: [
            'サンプルストア',
            'コーヒー 180',
            'サンド 550 x2',
            '合計 1280',
            '現金'
          ]
        }
      end

      it 'linesからフォールバックで明細を組み立てる' do
        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        items = params[:receipt_items_attributes]

        aggregate_failures do
          expect(items.size).to eq(2)
          expect(items.first[:raw_text]).to eq('コーヒー 180')
          expect(items.first[:price]).to eq(180)
          expect(items.first[:quantity]).to eq(1)
          expect(items.first[:line_total]).to eq(180)

          expect(items.second[:raw_text]).to eq('サンド 550 x2')
          expect(items.second[:price]).to eq(550)
          expect(items.second[:quantity]).to eq(2)
          expect(items.second[:line_total]).to eq(1100)
        end
      end
    end

    context '文字列の数値が混在する場合' do
      let(:ocr_result) do
        {
          candidates: {
            total_amount: '1,280円',
            subtotal_amount: '1,180円',
            tax_amount: '80円',
            tax_rate: '10%',
            tip_amount: '100円',
            payment_method_text: 'Master',
            items: [
              {
                raw_text: 'コーヒー',
                price: '180円',
                quantity: '1',
                line_total: '180円'
              }
            ],
            payments: [
              { method: 'CreditCard', amount: '1,280円' }
            ],
            tax_details: [
              { description: 'Sales Tax', amount: '80円', rate: '10%', net_amount: '800円' }
            ]
          },
          lines: []
        }
      end

      it '保存向けに正規化する' do
        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          expect(params[:receipt_attributes][:total_amount]).to eq(1280)
          expect(params[:receipt_attributes][:subtotal_amount]).to eq(1180)
          expect(params[:receipt_attributes][:tax_amount]).to eq(80)
          expect(params[:receipt_attributes][:tax_rate].to_i).to eq(10)
          expect(params[:receipt_attributes][:tip_amount]).to eq(100)
          expect(params[:receipt_items_attributes].first[:price]).to eq(180)
          expect(params[:receipt_payments_attributes].first[:amount]).to eq(1280)
          expect(params[:receipt_tax_details_attributes].first[:net_amount]).to eq(800)
        end
      end
    end
  end
end
