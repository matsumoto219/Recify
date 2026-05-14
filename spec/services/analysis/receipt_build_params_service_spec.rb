require 'rails_helper'

RSpec.describe Analysis::ReceiptBuildParamsService do
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
          expect(params[:receipt_attributes][:tax_rate]).to eq(BigDecimal("0.1"))
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

      it '小数quantityとquantity_unitを保持する' do
        ocr_result[:candidates][:items].first[:quantity] = 0.3
        ocr_result[:candidates][:items].first[:quantity_unit] = 'kg'

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)
        item = params[:receipt_items_attributes].first

        aggregate_failures do
          expect(item[:quantity]).to eq(BigDecimal('0.3'))
          expect(item[:quantity_unit]).to eq('kg')
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
          expect(tax[:rate]).to eq(BigDecimal("0.1"))
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
              index: 0,
              suggested_name: 'ブレンドコーヒー',
              category: 'drink',
              needs_review: false
            },
            {
              index: 1,
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
          expect(params[:receipt_attributes][:tax_rate]).to eq(BigDecimal("0.1"))
          expect(params[:receipt_attributes][:tip_amount]).to eq(100)
          expect(params[:receipt_items_attributes].first[:price]).to eq(180)
          expect(params[:receipt_payments_attributes].first[:amount]).to eq(1280)
          expect(params[:receipt_tax_details_attributes].first[:net_amount]).to eq(800)
        end
      end

      it 'quantityだけはdecimal commaを小数として正規化する' do
        ocr_result[:candidates][:items].first[:price] = '14,400円'
        ocr_result[:candidates][:items].first[:quantity] = '0,300'
        ocr_result[:candidates][:items].first[:quantity_unit] = 'kg'
        ocr_result[:candidates][:items].first[:line_total] = nil

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)
        item = params[:receipt_items_attributes].first

        aggregate_failures do
          expect(item[:price]).to eq(14_400)
          expect(item[:quantity]).to eq(BigDecimal('0.300'))
          expect(item[:quantity_unit]).to eq('kg')
          expect(item[:line_total]).to eq(4_320)
        end
      end
    end

    context 'payment_method_text が判定不能な場合' do
      let(:ocr_result) do
        {
          candidates: {
            store_name: 'サンプルストア',
            total_amount: 1280,
            payment_method_text: '不明な決済文言',
            items: [],
            payments: [],
            tax_details: []
          },
          lines: []
        }
      end

      it 'payment_method は nil になる' do
        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:payment_method]).to be_nil
      end
    end

    context 'line_total が欠けている場合' do
      let(:ocr_result) do
        {
          candidates: {
            payment_method_text: 'Master',
            items: [
              {
                raw_text: 'サンド',
                price: 550,
                quantity: 2,
                line_total: nil
              }
            ],
            payments: [],
            tax_details: []
          },
          lines: []
        }
      end

      it 'price と quantity から line_total を補完する' do
        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        item = params[:receipt_items_attributes].first

        aggregate_failures do
          expect(item[:price]).to eq(550)
          expect(item[:quantity]).to eq(2)
          expect(item[:line_total]).to eq(1100)
        end
      end
    end

    context 'quantity が空の場合' do
      let(:ocr_result) do
        {
          candidates: {
            payment_method_text: 'Master',
            items: [
              {
                raw_text: 'コーヒー',
                price: 180,
                quantity: nil,
                line_total: nil
              }
            ],
            payments: [],
            tax_details: []
          },
          lines: []
        }
      end

      it 'quantity は 1 として扱われる' do
        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        item = params[:receipt_items_attributes].first

        aggregate_failures do
          expect(item[:quantity]).to eq(1)
          expect(item[:line_total]).to eq(180)
        end
      end
    end

    context 'OCRとAIの明細件数がズレる場合' do
      context 'OCR 2件 / AI 1件の場合' do
        let(:ocr_result) do
          {
            candidates: {
              payment_method_text: 'Master',
              items: [
                {
                  raw_text: 'コーヒー',
                  price: 180,
                  quantity: 1,
                  quantity_unit: '杯',
                  product_code: 'C001',
                  line_total: 180
                },
                {
                  raw_text: 'サンド',
                  price: 550,
                  quantity: 2,
                  quantity_unit: '個',
                  product_code: 'S001',
                  line_total: 1100
                }
              ],
              payments: [],
              tax_details: []
            },
            lines: []
          }
        end

        let(:ai_result) do
          {
            receipt_items_attributes: [
              {
                index: 0,
                suggested_name: 'ブレンドコーヒー',
                category: 'drink',
                needs_review: false
              }
            ]
          }
        end

        it '不足分はOCR側の明細を保持する' do
          params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)

          first_item = params[:receipt_items_attributes].first
          second_item = params[:receipt_items_attributes].second

          aggregate_failures do
            expect(params[:receipt_items_attributes].size).to eq(2)
            expect(first_item[:suggested_name]).to eq('ブレンドコーヒー')
            expect(first_item[:quantity_unit]).to eq('杯')
            expect(second_item[:raw_text]).to eq('サンド')
            expect(second_item[:quantity_unit]).to eq('個')
            expect(second_item[:product_code]).to eq('S001')
          end
        end
      end

      context 'OCR 1件 / AI 2件の場合' do
        let(:ocr_result) do
          {
            candidates: {
              payment_method_text: 'Master',
              items: [
                {
                  raw_text: 'コーヒー',
                  price: 180,
                  quantity: 1,
                  quantity_unit: '杯',
                  product_code: 'C001',
                  line_total: 180
                }
              ],
              payments: [],
              tax_details: []
            },
            lines: []
          }
        end

        let(:ai_result) do
          {
            receipt_items_attributes: [
              {
                index: 0,
                suggested_name: 'ブレンドコーヒー',
                category: 'drink',
                needs_review: false
              },
              {
                index: 1,
                suggested_name: 'たまごサンド',
                category: 'food',
                needs_review: true
              }
            ]
          }
        end

        it '余分なAI明細は追加されず OCR側の明細だけを保持する' do
          params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)

          first_item = params[:receipt_items_attributes].first
          second_item = params[:receipt_items_attributes].second

          aggregate_failures do
            expect(params[:receipt_items_attributes].size).to eq(1)
            expect(first_item[:raw_text]).to eq('コーヒー')
            expect(first_item[:quantity_unit]).to eq('杯')
            expect(first_item[:product_code]).to eq('C001')
            expect(first_item[:suggested_name]).to eq('ブレンドコーヒー')
            expect(first_item[:category]).to eq('drink')
            expect(first_item[:needs_review]).to eq(false)
            expect(second_item).to be_nil
          end
        end
      end
    end

    context 'purchased_at_text が不正な場合' do
      let(:ocr_result) do
        {
          candidates: {
            store_name: 'サンプルストア',
            purchased_at_text: 'not-a-date',
            total_amount: 1280,
            payment_method_text: 'Master',
            items: [],
            payments: [],
            tax_details: []
          },
          lines: []
        }
      end

      it '例外を起こさず purchased_at は nil になる' do
        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:purchased_at]).to be_nil
      end
    end

    context 'processing_error 系と ocr_completed_at を引き継ぐ場合' do
      let(:ai_result) do
        {
          receipt_attributes: {
            processing_error_code: 'analysis_missing_keys',
            processing_error_message: 'missing required keys',
            ocr_completed_at: Time.zone.parse('2026-04-02 12:34:56')
          }
        }
      end

      it 'receipt_attributes にそのまま含める' do
        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)

        aggregate_failures do
          expect(params[:receipt_attributes][:processing_error_code]).to eq('analysis_missing_keys')
          expect(params[:receipt_attributes][:processing_error_message]).to eq('missing required keys')
          expect(params[:receipt_attributes][:ocr_completed_at]).to eq(Time.zone.parse('2026-04-02 12:34:56'))
        end
      end
    end

    context '文字列キーの入力が混在する場合' do
      let(:ocr_result) do
        {
          'candidates' => {
            'store_name' => 'サンプルストア',
            'payment_method_text' => 'Master',
            'items' => [
              {
                'raw_text' => 'コーヒー',
                'price' => '180円',
                'quantity' => '1',
                'quantity_unit' => '杯',
                'product_code' => 'C001',
                'line_total' => '180円'
              }
            ],
            'payments' => [
              { 'method' => 'CreditCard', 'amount' => '1,280円' }
            ],
            'tax_details' => [
              { 'description' => 'Sales Tax', 'amount' => '80円', 'rate' => '10%', 'net_amount' => '800円' }
            ]
          },
          'lines' => []
        }
      end

      it 'symbolize しながら保存向けに正しく整形できる' do
        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        first_item = params[:receipt_items_attributes].first
        first_payment = params[:receipt_payments_attributes].first
        first_tax_detail = params[:receipt_tax_details_attributes].first

        aggregate_failures do
          expect(params[:receipt_attributes][:store_name]).to eq('サンプルストア')
          expect(params[:receipt_attributes][:payment_method]).to eq('credit_card')
          expect(first_item[:raw_text]).to eq('コーヒー')
          expect(first_item[:quantity_unit]).to eq('杯')
          expect(first_item[:product_code]).to eq('C001')
          expect(first_item[:price]).to eq(180)
          expect(first_payment[:amount]).to eq(1280)
          expect(first_tax_detail[:net_amount]).to eq(800)
        end
      end
    end
  end
end
