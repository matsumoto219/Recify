require 'rails_helper'

RSpec.describe Analysis::ReceiptBuildParamsService do
  describe '.call' do
    def ocr_fixture(name)
      raw_json = JSON.parse(Rails.root.join("spec/fixtures/ocr/#{name}.json").read)

      Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call
    end

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
          country_region: 'JPN',
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
          expect(params[:receipt_attributes][:country_region]).to eq('JPN')
          expect(params[:receipt_attributes][:receipt_type]).to eq('Meal')
          expect(params[:receipt_attributes][:payment_method]).to eq('credit_card')
          expect(params[:receipt_attributes][:purchased_at]).to be_present
        end
      end

      it 'country_regionは保存前に3文字uppercaseへ正規化する' do
        ocr_result[:candidates][:country_region] = ' jpn '

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:country_region]).to eq('JPN')
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

      it 'payment_method_text が空の場合は Payments[] から credit_card を推定する' do
        ocr_result[:candidates][:payment_method_text] = nil
        ocr_result[:candidates][:payments] = [
          { method: 'VISA Credit', amount: 1280 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          expect(params[:receipt_attributes][:payment_method]).to eq('credit_card')
          expect(params[:receipt_payments_attributes].first[:method]).to eq('VISA Credit')
        end
      end

      it 'payment_method_text が空の場合は Payments[] から cash を推定する' do
        ocr_result[:candidates][:payment_method_text] = nil
        ocr_result[:candidates][:payments] = [
          { method: '現金', amount: 1280 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:payment_method]).to eq('cash')
      end

      it 'payment_method_text が強い場合は Payments[] より優先する' do
        ocr_result[:candidates][:payment_method_text] = 'PayPay'
        ocr_result[:candidates][:payments] = [
          { method: '現金', amount: 1280 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:payment_method]).to eq('qr_payment')
      end

      it '未知の Payments[] は payment_method を無理に埋めない' do
        ocr_result[:candidates][:payment_method_text] = nil
        ocr_result[:candidates][:payments] = [
          { method: '不明な支払い', amount: 1280 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:payment_method]).to be_nil
      end

      it 'Payments[] が複数件ある場合も全件保存する' do
        ocr_result[:candidates][:payment_method_text] = nil
        ocr_result[:candidates][:payments] = [
          { method: '現金', amount: 500 },
          { method: 'VISA Credit', amount: 780 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          expect(params[:receipt_payments_attributes]).to contain_exactly(
            include(method: '現金', amount: 500),
            include(method: 'VISA Credit', amount: 780)
          )
          expect(params[:receipt_attributes][:payment_method]).to eq('credit_card')
        end
      end

      it 'point + credit では point を代表値にせず credit_card を選ぶ' do
        ocr_result[:candidates][:payment_method_text] = nil
        ocr_result[:candidates][:payments] = [
          { method: 'WAON POINT', amount: 280 },
          { method: 'JCB', amount: 1000 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:payment_method]).to eq('credit_card')
      end

      it 'coupon + cash では coupon を代表値にせず cash を選ぶ' do
        ocr_result[:candidates][:payment_method_text] = nil
        ocr_result[:candidates][:payments] = [
          { method: 'クーポン', amount: 100 },
          { method: '現金', amount: 1180 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:payment_method]).to eq('cash')
      end

      it 'coupon + credit では coupon を代表値にせず credit_card を選ぶ' do
        ocr_result[:candidates][:payment_method_text] = nil
        ocr_result[:candidates][:payments] = [
          { method: 'クーポン', amount: 100 },
          { method: 'MasterCard', amount: 1180 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:payment_method]).to eq('credit_card')
      end

      it '商品券 + cash では商品券を代表値にせず cash を選ぶ' do
        ocr_result[:candidates][:payment_method_text] = nil
        ocr_result[:candidates][:payments] = [
          { method: '商品券', amount: 500 },
          { method: '現金', amount: 780 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:payment_method]).to eq('cash')
      end

      it 'pointのみでは payment_method を無理に埋めない' do
        ocr_result[:candidates][:payment_method_text] = nil
        ocr_result[:candidates][:payments] = [
          { method: 'ポイント利用', amount: 1280 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:payment_method]).to be_nil
      end

      it '商品券のみでは payment_method を無理に埋めない' do
        ocr_result[:candidates][:payment_method_text] = nil
        ocr_result[:candidates][:payments] = [
          { method: '商品券', amount: 1280 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:payment_method]).to be_nil
      end

      it '複数の実決済手段では固定優先順位で代表値を選ぶ' do
        ocr_result[:candidates][:payment_method_text] = nil
        ocr_result[:candidates][:payments] = [
          { method: '現金', amount: 300 },
          { method: 'Suica', amount: 400 },
          { method: 'PayPay', amount: 580 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:payment_method]).to eq('cash')
      end

      it 'OCR payment_method_text がある場合は複合 Payments[] より優先する' do
        ocr_result[:candidates][:payment_method_text] = 'PayPay'
        ocr_result[:candidates][:payments] = [
          { method: '現金', amount: 500 },
          { method: 'VISA Credit', amount: 780 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:payment_method]).to eq('qr_payment')
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

      it '単一税率のpositive tax_detailsがある場合はitem tax_rateを補完する' do
        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        tax_rates = params[:receipt_items_attributes].map { |item| item[:tax_rate] }

        expect(tax_rates).to contain_exactly(BigDecimal('0.1'), BigDecimal('0.1'))
      end

      it '既存item tax_rateが1つでもある場合は補完しない' do
        ocr_result[:candidates][:items].first[:tax_rate] = 8

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)
        items = params[:receipt_items_attributes]

        aggregate_failures do
          expect(items.first[:tax_rate]).to eq(BigDecimal('0.08'))
          expect(items.second[:tax_rate]).to be_nil
        end
      end

      it '単一税率の印字税内訳が合計全体に一致する場合はAI item税率より優先する' do
        rvmu_like_ocr_result = {
          candidates: {
            store_name: 'サンプル食堂',
            total_amount: 1_391,
            tax_amount: 126,
            country_region: 'JPN',
            items: [
              {
                raw_text: '牛丼並',
                price: 450,
                quantity: 2,
                line_total: 900,
                confidence: 0.95
              },
              {
                raw_text: 'サラダセット',
                price: 200,
                quantity: 2,
                line_total: 400,
                confidence: 0.95
              }
            ],
            tax_details: [
              { description: '内消費税', amount: 126, rate: 10 }
            ]
          },
          lines: [
            '※は軽減税率適用商品',
            '深夜料(*)',
            '¥91',
            '合計',
            '¥1,391',
            '(10%対象',
            '¥1,391内消費税',
            '¥126)'
          ]
        }
        ai_result = {
          receipt_items_attributes: [
            { index: 0, category: 'food', tax_rate: 0.08, tax_rate_reason: 'reduced_rate', tax_rate_confidence: 0.98 },
            { index: 1, category: 'food', tax_rate: 0.08, tax_rate_reason: 'reduced_rate', tax_rate_confidence: 0.98 }
          ],
          receipt_adjustments_attributes: [
            {
              kind: 'late_night_charge',
              label: '深夜料',
              amount: 91,
              sign: 'surcharge',
              tax_rate: 0.08,
              source_text: '深夜料(*)',
              source_line_index: 1,
              confidence: 0.97
            }
          ]
        }

        params = described_class.call(ocr_result: rvmu_like_ocr_result, ai_result: ai_result)

        aggregate_failures do
          expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to eq([ BigDecimal('0.1'), BigDecimal('0.1') ])
          expect(params[:receipt_adjustments_attributes].pluck(:kind, :amount, :tax_rate)).to eq([
            [ 'late_night_charge', 91, BigDecimal('0.1') ]
          ])
          expect(params[:tax_rate_correction]).to include(
            reason: 'single_tax_detail_total_matches_receipt_total',
            source: 'printed_tax_detail',
            rate: '0.1',
            item_count: 2,
            adjustment_count: 1
          )
        end
      end

      it '複数税率の税率別対象額が明細/調整額へ一意一致する場合はAI税率より優先する' do
        lindt_like_ocr_result = {
          candidates: {
            store_name: 'Sample Sweets',
            total_amount: 5_000,
            subtotal_amount: 2_204,
            tax_amount: 164,
            country_region: 'JPN',
            items: [
              { raw_text: 'MIX SWEETS', price: 14_400, quantity: 0.3, quantity_unit: 'kg', line_total: 4_320, confidence: 0.95 },
              { raw_text: 'Short Dated Stock Discount', line_total: -2_160, confidence: 0.94 },
              { raw_text: 'アウトレット袋S', price: 44, quantity: 1, line_total: 44, confidence: 0.95 }
            ],
            tax_details: [
              { description: '軽', rate: 8, net_amount: 2_160, amount: 160 },
              { description: '10%', rate: 10, net_amount: 44, amount: 4 }
            ]
          },
          lines: [
            'MIX SWEETS',
            '4,320 軽',
            'Short Dated Stock Discount',
            '-2,160',
            'アウトレット袋S',
            '44',
            '軽 8%',
            '¥2,160',
            '¥160',
            '10%',
            '¥44',
            '¥4'
          ]
        }
        ai_result = {
          receipt_items_attributes: [
            { index: 0, category: 'food', tax_rate: 0.08, tax_rate_reason: 'reduced_rate', tax_rate_confidence: 0.96 },
            { index: 2, category: 'daily_goods', tax_rate: 0.08, tax_rate_reason: 'reduced_rate', tax_rate_confidence: 0.9 }
          ],
          receipt_adjustments_attributes: [
            {
              kind: 'receipt_discount',
              label: 'Short Dated Stock Discount',
              amount: 2_160,
              sign: 'discount',
              tax_rate: 0.1,
              source_text: 'Short Dated Stock Discount',
              source_line_index: 2,
              confidence: 0.98
            }
          ]
        }

        params = described_class.call(ocr_result: lindt_like_ocr_result, ai_result: ai_result)

        aggregate_failures do
          expect(params[:receipt_items_attributes].pluck(:raw_text, :line_total, :tax_rate)).to contain_exactly(
            [ 'MIX SWEETS', 4_320, BigDecimal('0.08') ],
            [ 'アウトレット袋S', 44, BigDecimal('0.1') ]
          )
          expect(params[:receipt_adjustments_attributes].pluck(:kind, :amount, :tax_rate)).to eq([
            [ 'receipt_discount', 2_160, BigDecimal('0.08') ]
          ])
          expect(params[:tax_rate_correction]).to include(
            reason: 'tax_detail_amount_match',
            source: 'printed_tax_detail',
            item_count: 1,
            adjustment_count: 1
          )
          expect(params.dig(:corrections, :tax_rate_correction)).to eq(params[:tax_rate_correction])
          expect(params[:tax_rate_correction][:matches]).to contain_exactly(
            { target: 'item', amount: 44, rate: '0.1' },
            { target: 'adjustment', amount: 2_160, rate: '0.08' }
          )
        end
      end

      it '海外風VAT summaryでも税率別対象額と明細額の一致を優先する' do
        vat_ocr_result = {
          candidates: {
            store_name: 'Sample Store',
            total_amount: 2_204,
            tax_amount: 164,
            country_region: 'USA',
            items: [
              { raw_text: 'Item A', line_total: 2_160, confidence: 0.95 },
              { raw_text: 'Bag fee', line_total: 44, confidence: 0.95 }
            ],
            tax_details: [
              { description: 'VAT 8% taxable amount', rate: 8, net_amount: 2_160, amount: 160 },
              { description: 'VAT 10% taxable amount', rate: 10, net_amount: 44, amount: 4 }
            ]
          },
          lines: []
        }

        params = described_class.call(ocr_result: vat_ocr_result, ai_result: nil)

        expect(params[:receipt_items_attributes].pluck(:raw_text, :tax_rate)).to contain_exactly(
          [ 'Item A', BigDecimal('0.08') ],
          [ 'Bag fee', BigDecimal('0.1') ]
        )
      end

      it '税率別対象額に同額明細が複数ある場合は補正しない' do
        ambiguous_ocr_result = {
          candidates: {
            items: [
              { raw_text: 'Item A', line_total: 44, confidence: 0.95 },
              { raw_text: 'Item B', line_total: 44, confidence: 0.95 }
            ],
            tax_details: [
              { description: 'VAT 10%', rate: 10, net_amount: 44, amount: 4 },
              { description: 'VAT 8%', rate: 8, net_amount: 100, amount: 7 }
            ]
          },
          lines: []
        }

        params = described_class.call(ocr_result: ambiguous_ocr_result, ai_result: nil)

        aggregate_failures do
          expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to all(be_nil)
          expect(params[:tax_rate_correction]).to be_nil
        end
      end

      it '税率別対象額が複数明細の合算にしか一致しない場合は補正しない' do
        summed_ocr_result = {
          candidates: {
            items: [
              { raw_text: 'Item A', line_total: 600, confidence: 0.95 },
              { raw_text: 'Item B', line_total: 400, confidence: 0.95 }
            ],
            tax_details: [
              { description: 'VAT 8%', rate: 8, net_amount: 1_000, amount: 80 },
              { description: 'VAT 10%', rate: 10, net_amount: 44, amount: 4 }
            ]
          },
          lines: []
        }

        params = described_class.call(ocr_result: summed_ocr_result, ai_result: nil)

        aggregate_failures do
          expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to all(be_nil)
          expect(params[:tax_rate_correction]).to be_nil
        end
      end

      it '複数税率のtax_detailsではitem tax_rateを補完しない' do
        ocr_result[:candidates][:tax_details] = [
          { description: '8%対象', amount: 40, rate: 8, net_amount: 500 },
          { description: '10%対象', amount: 50, rate: 10, net_amount: 500 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to all(be_nil)
      end

      it 'tax amountが0の場合はitem tax_rateを補完しない' do
        ocr_result[:candidates][:tax_details] = [
          { description: '8%対象', amount: 0, rate: 8, net_amount: 500 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to all(be_nil)
      end

      it 'tax_rateが0の場合はitem tax_rateを補完しない' do
        ocr_result[:candidates][:tax_details] = [
          { description: '0%対象', amount: 80, rate: 0, net_amount: 500 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to all(be_nil)
      end

      it 'tax_rateがnilの場合はitem tax_rateを補完しない' do
        ocr_result[:candidates][:tax_details] = [
          { description: '税額', amount: 80, rate: nil, net_amount: 500 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to all(be_nil)
      end

      it 'tax_detailsが空の場合はitem tax_rateを補完しない' do
        ocr_result[:candidates][:tax_details] = []

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to all(be_nil)
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
          expect(params[:receipt_attributes][:country_region]).to eq('JPN')
          expect(params[:receipt_attributes][:receipt_type]).to eq('Meal')
        end
      end

      it 'AI payment_method は OCR field や Payments[] より優先される' do
        ocr_result[:candidates][:payment_method_text] = 'Master'
        ocr_result[:candidates][:payments] = [
          { method: '現金', amount: 500 },
          { method: 'VISA Credit', amount: 780 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)

        expect(params[:receipt_attributes][:payment_method]).to eq('qr_payment')
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

      it 'AIが未知カテゴリを返した場合はカテゴリ未設定かつ確認対象にする' do
        ai_result[:receipt_items_attributes].first.merge!(
          category: 'unknown_category',
          needs_review: false
        )

        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)
        item = params[:receipt_items_attributes].first

        aggregate_failures do
          expect(item[:category]).to be_nil
          expect(item[:needs_review]).to eq(true)
          expect(item[:review_reasons]).to include('item_category_uncertain')
        end
      end

      it 'tax_rate confidence が高い場合は warning reason を追加しない' do
        ai_result[:receipt_items_attributes].first.merge!(
          tax_rate: 0.1,
          tax_rate_confidence: 0.9,
          tax_rate_reason: 'standard_rate'
        )

        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)
        item = params[:receipt_items_attributes].first

        aggregate_failures do
          expect(item[:tax_rate]).to eq(BigDecimal('0.1'))
          expect(item[:review_reasons]).not_to include('item_tax_rate_uncertain')
          expect(item[:needs_review]).to eq(false)
          expect(item).not_to have_key(:tax_rate_confidence)
          expect(item).not_to have_key(:tax_rate_reason)
        end
      end

      it 'tax_rate confidence が低い場合は review にせず warning reason を追加する' do
        ai_result[:receipt_items_attributes].first.merge!(
          tax_rate: 0.1,
          tax_rate_confidence: 0.42,
          tax_rate_reason: 'receipt_context_uncertain',
          needs_review: true
        )

        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)
        item = params[:receipt_items_attributes].first

        aggregate_failures do
          expect(item[:tax_rate]).to eq(BigDecimal('0.1'))
          expect(item[:review_reasons]).to include('item_tax_rate_uncertain')
          expect(item[:needs_review]).to eq(false)
          expect(item).not_to have_key(:tax_rate_confidence)
          expect(item).not_to have_key(:tax_rate_reason)
        end
      end

      it 'tax_rate が nil で confidence が低い場合は従来どおり要確認にする' do
        ai_result[:receipt_items_attributes].first.merge!(
          tax_rate: nil,
          tax_rate_confidence: 0.35,
          tax_rate_reason: 'tax_rate_not_visible',
          needs_review: false
        )

        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)
        item = params[:receipt_items_attributes].first

        aggregate_failures do
          expect(item[:tax_rate]).to eq(BigDecimal('0.1'))
          expect(item[:review_reasons]).to include('item_tax_rate_uncertain')
          expect(item[:needs_review]).to eq(true)
          expect(item).not_to have_key(:tax_rate_confidence)
          expect(item).not_to have_key(:tax_rate_reason)
        end
      end
    end

    context '実OCR fixtureからtax_rateを補完する場合' do
      it 'single_tax_receipt は単一税率で補完される' do
        params = described_class.call(ocr_result: ocr_fixture('single_tax_receipt'), ai_result: nil)

        expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to all(eq(BigDecimal('0.1')))
      end

      it 'zero_tax_receipt は0税額なので補完されない' do
        params = described_class.call(ocr_result: ocr_fixture('zero_tax_receipt'), ai_result: nil)

        expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to all(be_nil)
      end

      it 'multiple_tax_receipt は複数税率なので補完されない' do
        params = described_class.call(ocr_result: ocr_fixture('multiple_tax_receipt'), ai_result: nil)

        expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to all(be_nil)
      end

      it 'external_tax_receipt は複数税率なので補完されない' do
        params = described_class.call(ocr_result: ocr_fixture('external_tax_receipt'), ai_result: nil)

        expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to all(be_nil)
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

      it 'comma付き金額を1円として誤読せずfallback明細を組み立てる' do
        ocr_result[:lines] = [
          'サンプルストア',
          '商品A 1,234',
          '商品B ¥4,320',
          '商品C 1 234',
          '合計 6788',
          '現金'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)
        items = params[:receipt_items_attributes]

        aggregate_failures do
          expect(items.size).to eq(3)
          expect(items.first[:price]).to eq(1_234)
          expect(items.first[:line_total]).to eq(1_234)
          expect(items.second[:price]).to eq(4_320)
          expect(items.second[:line_total]).to eq(4_320)
          expect(items.third[:price]).to eq(1_234)
          expect(items.third[:line_total]).to eq(1_234)
        end
      end

      it '非明細行をfallback明細にしない' do
        ocr_result[:lines] = [
          'サンプルストア',
          '小計 1000',
          '消費税 80',
          '税額 80',
          '税込 1080',
          '税抜 1000',
          'TEL 03-1234-5678',
          '住所 東京都港区芝1-1-1',
          '登録番号 T1234567890123',
          'インボイス T1234567890123',
          '伝票番号 123456',
          '取引番号 987654',
          'レシート番号 111222',
          '2026/05/20 12:34',
          '販売期間 2026年5月20日(水)~6月30日(火)',
          'https://example.com/receipt/123',
          'support@example.com',
          '商品A 1,234'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)
        items = params[:receipt_items_attributes]

        aggregate_failures do
          expect(items.size).to eq(1)
          expect(items.first[:raw_text]).to eq('商品A 1,234')
          expect(items.first[:price]).to eq(1_234)
          expect(items.first[:line_total]).to eq(1_234)
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

      it 'integer-only unitの小数quantityは未確定扱いで1にfallbackする' do
        ocr_result[:candidates][:items].first[:price] = '100円'
        ocr_result[:candidates][:items].first[:quantity] = '1.5'
        ocr_result[:candidates][:items].first[:quantity_unit] = '個'
        ocr_result[:candidates][:items].first[:line_total] = nil

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)
        item = params[:receipt_items_attributes].first

        aggregate_failures do
          expect(item[:quantity]).to eq(BigDecimal('1'))
          expect(item[:line_total]).to eq(100)
          expect(item[:needs_review]).to be(true)
          expect(item[:review_reasons]).to include('item_quantity_uncertain')
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

    context 'price が欠けている場合' do
      let(:ocr_result) do
        {
          candidates: {
            payment_method_text: 'Master',
            items: [
              {
                raw_text: 'コーヒー',
                price: nil,
                quantity: 1,
                original_line_total: 500,
                discount_amount: nil,
                line_total: 500
              },
              {
                raw_text: 'サンド',
                price: nil,
                quantity: 2,
                original_line_total: 600,
                discount_amount: nil,
                line_total: 600
              },
              {
                raw_text: '割引サンド',
                price: nil,
                quantity: 2,
                original_line_total: 600,
                discount_amount: 300,
                line_total: 300
              }
            ],
            payments: [],
            tax_details: []
          },
          lines: []
        }
      end

      it '割引前行合計から税込単価を補完しline_totalは割引後で保持する' do
        params = described_class.call(ocr_result: ocr_result, ai_result: nil)
        items = params[:receipt_items_attributes]

        aggregate_failures do
          expect(items.first[:price]).to eq(500)
          expect(items.first[:original_line_total]).to eq(500)
          expect(items.first[:line_total]).to eq(500)

          expect(items.second[:price]).to eq(300)
          expect(items.second[:original_line_total]).to eq(600)
          expect(items.second[:line_total]).to eq(600)

          expect(items.third[:price]).to eq(300)
          expect(items.third[:original_line_total]).to eq(600)
          expect(items.third[:discount_amount]).to eq(300)
          expect(items.third[:line_total]).to eq(300)
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

    context '購入日付だけに一意な時刻候補を補完する場合' do
      let(:parking_receipt_ocr_result) do
        {
          candidates: {
            store_name: 'サンプル公園駐車場',
            purchased_at_text: '2026-04-19',
            total_amount: 500,
            payment_method_text: '現金',
            items: [
              { raw_text: '駐車券自家用車等', line_total: 500, confidence: 0.975 }
            ],
            payments: [],
            tax_details: []
          },
          lines: [
            '2026年 4月19日(日)No2',
            '駐車券自家用車等',
            '0796 16時41分'
          ]
        }
      end

      it 'AIが日付のみを返してもOCRの一意な時刻候補を結合する' do
        ai_result = {
          receipt_attributes: {
            purchased_at_text: '2026-04-19'
          },
          receipt_items_attributes: []
        }

        params = described_class.call(ocr_result: parking_receipt_ocr_result, ai_result: ai_result)

        aggregate_failures do
          expect(params[:receipt_attributes][:purchased_at]).to eq(Time.zone.parse('2026-04-19 16:41'))
          expect(params.dig(:corrections, :purchased_at_fallback)).to include(
            applied: true,
            source: 'ocr_time_candidate',
            date_text: '2026-04-19',
            time_text: '16時41分',
            normalized_time: '16:41',
            ignored_prefix: '0796',
            source_text: '0796 16時41分',
            result: '2026-04-19 16:41'
          )
        end
      end

      it '時刻候補の前にあるレシート番号らしき数字を時刻に混ぜない' do
        params = described_class.call(ocr_result: parking_receipt_ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:purchased_at].strftime('%H:%M')).to eq('16:41')
      end

      it 'コロン区切りの時刻候補も結合する' do
        parking_receipt_ocr_result[:lines] = [
          '2026年 4月19日(日)No2',
          '0796 16:41'
        ]

        params = described_class.call(ocr_result: parking_receipt_ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:purchased_at]).to eq(Time.zone.parse('2026-04-19 16:41'))
      end

      it '時刻候補が複数ある場合は結合しない' do
        parking_receipt_ocr_result[:lines] = [
          '2026年 4月19日(日)No2',
          '入庫 15時20分',
          '0796 16時41分'
        ]

        params = described_class.call(ocr_result: parking_receipt_ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:purchased_at]).to eq(Time.zone.parse('2026-04-19'))
      end

      it 'AIが明確な日時を返した場合はAI値を優先する' do
        ai_result = {
          receipt_attributes: {
            purchased_at_text: '2026-04-19 17:05'
          },
          receipt_items_attributes: []
        }

        params = described_class.call(ocr_result: parking_receipt_ocr_result, ai_result: ai_result)

        expect(params[:receipt_attributes][:purchased_at]).to eq(Time.zone.parse('2026-04-19 17:05'))
      end

      it '日付のみで時刻候補がない場合は従来通り日付のみを保存する' do
        parking_receipt_ocr_result[:lines] = [ '2026年 4月19日(日)No2' ]

        params = described_class.call(ocr_result: parking_receipt_ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:purchased_at]).to eq(Time.zone.parse('2026-04-19'))
      end

      it '非購入文脈の時刻だけでは補完しない' do
        parking_receipt_ocr_result[:lines] = [
          '2026年 4月19日(日)No2',
          '予約 16時41分'
        ]

        params = described_class.call(ocr_result: parking_receipt_ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:purchased_at]).to eq(Time.zone.parse('2026-04-19'))
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

    context '特殊加減算行' do
      let(:ocr_result) do
        {
          candidates: {
            store_name: 'サンプルストア',
            total_amount: 1_640,
            payment_method_text: '現金',
            items: [
              { raw_text: '商品小計', line_total: 1_080 },
              { raw_text: '配送料', line_total: 550 },
              { raw_text: 'レジ袋代', line_total: 10 }
            ],
            payments: [],
            tax_details: []
          },
          lines: [
            '商品小計',
            '¥1,080',
            'レジ袋代',
            '¥10',
            '配送料',
            '¥550',
            '合計',
            '¥1,640'
          ]
        }
      end

      it 'AI adjustmentをOCRに存在する金額だけ保存向けattributesへ通す' do
        ai_result = {
          receipt_adjustments_attributes: [
            {
              kind: 'bag_fee',
              label: 'レジ袋代',
              amount: 10,
              sign: 'surcharge',
              source_text: 'レジ袋代',
              source_line_index: 2,
              confidence: BigDecimal('0.9')
            },
            {
              kind: 'delivery_fee',
              label: '配送料',
              amount: 999,
              sign: 'surcharge',
              source_text: '配送料',
              source_line_index: 4
            }
          ]
        }

        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)

        aggregate_failures do
          expect(params[:receipt_adjustments_attributes]).to contain_exactly(
            include(kind: 'bag_fee', label: 'レジ袋代', amount: 10, sign: 'surcharge', source: 'ai')
          )
          expect(params[:receipt_adjustments_attributes]).not_to include(include(amount: 999))
        end
      end

      it 'ラベル行と金額行が分かれた深夜料金を近傍行照合で保存向けattributesへ通す' do
        ocr_result[:lines] = [
          '小計',
          '¥4,860',
          '深夜料金10%',
          '¥486',
          '合計',
          '¥5,346'
        ]
        ai_result = {
          receipt_adjustments_attributes: [
            {
              kind: 'late_night_charge',
              label: '深夜料金10%',
              amount: 486,
              sign: 'surcharge',
              source_text: '深夜料金10%',
              source_line_index: 2,
              confidence: BigDecimal('0.91')
            }
          ]
        }

        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)

        expect(params[:receipt_adjustments_attributes]).to contain_exactly(
          include(
            kind: 'late_night_charge',
            label: '深夜料金10%',
            amount: 486,
            sign: 'surcharge',
            source_line_index: 2
          )
        )
      end

      it '未知ラベルの調整行はotherかつneeds_reviewとして保存向けattributesへ通す' do
        ocr_result[:lines] = [
          '小計',
          '¥1,000',
          'ミッドナイトチャージ',
          '¥100',
          '合計',
          '¥1,100'
        ]
        ai_result = {
          receipt_adjustments_attributes: [
            {
              kind: 'unknown_charge',
              label: 'ミッドナイトチャージ',
              amount: 100,
              sign: 'surcharge',
              source_text: 'ミッドナイトチャージ',
              source_line_index: 2
            }
          ]
        }

        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)

        expect(params[:receipt_adjustments_attributes]).to contain_exactly(
          include(
            kind: 'other',
            label: 'ミッドナイトチャージ',
            amount: 100,
            sign: 'surcharge',
            needs_review: true,
            review_reasons: include('adjustment_uncertain')
          )
        )
      end

      it '英語や海外風の未知表記でもOCR近傍に金額があれば保存向けattributesへ通す' do
        ocr_result[:lines] = [
          'Subtotal',
          '$20.00',
          'After hours surcharge',
          '$3.00',
          'Manual adjustment',
          '-$2.00',
          'Total',
          '$21.00'
        ]
        ai_result = {
          receipt_adjustments_attributes: [
            {
              kind: 'late_night_charge',
              label: 'After hours surcharge',
              amount: 3,
              sign: 'surcharge',
              source_text: 'After hours surcharge',
              source_line_index: 2,
              confidence: BigDecimal('0.8')
            },
            {
              kind: 'unknown_adjustment',
              label: 'Manual adjustment',
              amount: 2,
              sign: 'discount',
              source_text: 'Manual adjustment',
              source_line_index: 4
            }
          ]
        }

        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)

        expect(params[:receipt_adjustments_attributes]).to contain_exactly(
          include(kind: 'late_night_charge', label: 'After hours surcharge', amount: 3, sign: 'surcharge'),
          include(kind: 'other', label: 'Manual adjustment', amount: 2, sign: 'discount', needs_review: true)
        )
      end

      it 'AI adjustmentがない場合だけ高信頼OCR candidateをsource ocrとしてfallback採用する' do
        ocr_result[:candidates][:adjustment_candidates] = [
          {
            source_text: '配送料',
            source_line_index: 4,
            neighboring_texts: { previous_text: '¥10', next_text: '¥550' },
            amount: 550,
            sign_hint: 'surcharge',
            tax_rate_hint: BigDecimal('0.1'),
            confidence: BigDecimal('0.86'),
            candidate_reason: 'label_next_amount',
            needs_review: true
          }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_adjustments_attributes]).to contain_exactly(
          include(
            kind: 'delivery_fee',
            label: '配送料',
            amount: 550,
            sign: 'surcharge',
            tax_rate: BigDecimal('0.1'),
            source: 'ocr',
            needs_review: true,
            review_reasons: include('adjustment_uncertain')
          )
        )
      end

      it 'AI adjustmentがある場合はOCR candidateへfallbackしない' do
        ocr_result[:candidates][:adjustment_candidates] = [
          {
            source_text: '配送料',
            source_line_index: 4,
            amount: 550,
            sign_hint: 'surcharge',
            confidence: BigDecimal('0.86')
          }
        ]
        ai_result = {
          receipt_adjustments_attributes: [
            {
              kind: 'bag_fee',
              label: 'レジ袋代',
              amount: 10,
              sign: 'surcharge',
              source_text: 'レジ袋代',
              source_line_index: 2
            }
          ]
        }

        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)

        expect(params[:receipt_adjustments_attributes]).to contain_exactly(
          include(kind: 'bag_fee', amount: 10, source: 'ai')
        )
      end

      it '低信頼または符号不明のOCR candidateはfallback採用しない' do
        ocr_result[:candidates][:adjustment_candidates] = [
          {
            source_text: '配送料',
            source_line_index: 4,
            amount: 550,
            sign_hint: 'surcharge',
            confidence: BigDecimal('0.6')
          },
          {
            source_text: '不明調整',
            source_line_index: 2,
            amount: 10,
            confidence: BigDecimal('0.9')
          }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_adjustments_attributes]).to eq([])
      end

      it 'OCR近傍に存在しない金額のcandidateはfallback採用しない' do
        ocr_result[:candidates][:adjustment_candidates] = [
          {
            source_text: '配送料',
            source_line_index: 4,
            amount: 999,
            sign_hint: 'surcharge',
            confidence: BigDecimal('0.9')
          }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_adjustments_attributes]).to eq([])
      end

      it '負値itemを通常明細から除外し、adjustmentがない場合は確認理由を付ける' do
        ocr_result[:candidates][:items] = [
          { raw_text: 'Short Dated Stock', line_total: -2160 }
        ]
        ocr_result[:lines] = [
          'Short Dated Stock -2160',
          '合計 0'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          expect(params[:receipt_items_attributes]).to be_empty
          expect(params[:review_reasons]).to eq([ 'adjustment_uncertain' ])
        end
      end
    end
  end
end
