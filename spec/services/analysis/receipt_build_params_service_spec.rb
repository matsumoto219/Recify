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
          store_address_components: {
            state: '東京都',
            city: '渋谷区',
            streetAddress: '1-2-3'
          },
          store_phone_number: '03-1234-5678',
          purchased_at_text: '2026/04/02 12:34',
          total_amount: 1280,
          subtotal_amount: 1180,
          tax_amount: 80,
          tax_rate: 10,
          tip_amount: 100,
          currency_code: 'jpy',
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
          expect(params[:receipt_attributes][:store_address_components]).to eq(
            'state' => '東京都',
            'city' => '渋谷区',
            'streetAddress' => '1-2-3'
          )
          expect(params[:receipt_attributes][:store_phone_number]).to eq('03-1234-5678')
          expect(params[:receipt_attributes][:total_amount]).to eq(1280)
          expect(params[:receipt_attributes][:subtotal_amount]).to eq(1180)
          expect(params[:receipt_attributes][:tax_amount]).to eq(80)
          expect(params[:receipt_attributes][:tax_rate]).to eq(BigDecimal("0.1"))
          expect(params[:receipt_attributes][:tip_amount]).to eq(100)
          expect(params[:receipt_attributes][:currency_code]).to eq('JPY')
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

      it 'currency_codeは保存前に3文字uppercaseへ正規化する' do
        ocr_result[:candidates][:currency_code] = ' usd '

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:currency_code]).to eq('USD')
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

      it 'OCR行に商品名と金額の根拠があるamount-only itemを後続name-only itemへ統合する' do
        ocr_result[:candidates][:items] = [
          {
            raw_text: '¥275',
            price: 275,
            line_total: 275,
            confidence: 0.59
          },
          {
            raw_text: 'Sample Kimchi Special',
            price: nil,
            line_total: 0,
            confidence: 0.93
          }
        ]
        ocr_result[:lines] = [
          'Sample Store',
          'Sample Kimchi Special ¥275'
        ]
        ai_result = {
          receipt_items_attributes: [
            {
              index: 0,
              suggested_name: '¥275',
              needs_review: true,
              review_reasons: [ 'item_name_uncertain' ]
            },
            {
              index: 1,
              suggested_name: 'Sample Kimchi Special',
              needs_review: false,
              review_reasons: []
            }
          ]
        }

        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)
        items = params[:receipt_items_attributes]

        aggregate_failures do
          expect(items.size).to eq(1)
          expect(items.first[:raw_text]).to eq('Sample Kimchi Special')
          expect(items.first[:suggested_name]).to eq('Sample Kimchi Special')
          expect(items.first[:price]).to eq(275)
          expect(items.first[:original_line_total]).to eq(275)
          expect(items.first[:line_total]).to eq(275)
          expect(items.first[:needs_review]).to be(false)
          expect(items.first[:review_reasons]).to be_empty
          expect(items.first[:confidence]).to eq(BigDecimal('0.59'))
        end
      end

      it 'OCR根拠がないamount-only itemは後続name-only itemへ統合しない' do
        ocr_result[:candidates][:items] = [
          {
            raw_text: '¥275',
            price: 275,
            line_total: 275,
            confidence: 0.59
          },
          {
            raw_text: 'Sample Kimchi Special',
            price: nil,
            line_total: nil,
            confidence: 0.93
          }
        ]
        ocr_result[:lines] = [
          'Sample Store',
          'Another Item ¥275'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)
        items = params[:receipt_items_attributes]

        aggregate_failures do
          expect(items.size).to eq(2)
          expect(items.first[:raw_text]).to eq('¥275')
          expect(items.first[:line_total]).to eq(275)
          expect(items.second[:raw_text]).to eq('Sample Kimchi Special')
          expect(items.second[:line_total]).to be_nil
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

      it 'PaymentMethods query field由来の補助候補だけでは payment_method を埋めない' do
        ocr_result[:candidates][:payment_method_text] = nil
        ocr_result[:candidates][:payments] = []
        ocr_result[:candidates][:payment_candidates] = [
          {
            source: 'query_field',
            field_name: 'PaymentMethods',
            method: 'PayPay ¥1,280',
            raw_text: 'PayPay ¥1,280',
            confidence: 0.82
          }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          expect(params[:receipt_attributes][:payment_method]).to be_nil
          expect(params[:receipt_payments_attributes]).to eq([])
        end
      end

      it 'Payments[] が空でも支払行と次行金額からreceipt_paymentsを補完する' do
        ocr_result[:candidates][:payment_method_text] = 'nanaco'
        ocr_result[:candidates][:payments] = []
        ocr_result[:lines] = [
          '合 計',
          '¥1,161',
          'キャッシュレス還元額',
          '-22',
          'nanaco支払',
          '¥1,139',
          'nanaco番号',
          '************ 9999'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          # 検算: レシート購入合計 1,161、キャッシュレス還元 -22、nanaco支払 1,139。
          expect(params[:receipt_payments_attributes]).to contain_exactly(
            include(method: 'nanaco支払', amount: 1_139)
          )
          expect(params[:receipt_attributes][:payment_method]).to eq('e_money')
        end
      end

      it 'QUICPayのOCR揺れでも支払行と次行金額からreceipt_paymentsを補完する' do
        ocr_result[:candidates][:payment_method_text] = 'qui cpay'
        ocr_result[:candidates][:payments] = []
        ocr_result[:candidates][:total_amount] = 4_215
        ocr_result[:lines] = [
          '合 計',
          '¥4,215',
          'qui cpay支払',
          '¥4,215',
          'お釣り',
          '¥0'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          # 検算: 支払行の次行金額 4,215 が購入合計 4,215 と一致する。
          expect(params[:receipt_payments_attributes]).to contain_exactly(
            include(method: 'qui cpay支払', amount: 4_215)
          )
          expect(params[:receipt_attributes][:payment_method]).to eq('e_money')
        end
      end

      it '主要な支払方法の表記揺れでもpayment_methodはカテゴリ化しreceipt_payments.methodは原文寄りで残す' do
        cases = [
          { line: '交通系IC支払', amount: 700, expected_category: 'e_money' },
          { line: '電子マネー決済', amount: 710, expected_category: 'e_money' },
          { line: 'タッチ決済', amount: 720, expected_category: 'e_money' },
          { line: 'contactless payment', amount: 730, expected_category: 'e_money' },
          { line: 'iD支払', amount: 735, expected_category: 'e_money' },
          { line: 'ID支払', amount: 736, expected_category: 'e_money' },
          { line: 'ｉＤ支払', amount: 737, expected_category: 'e_money', expected_method: 'iD支払' },
          { line: 'iD 500', amount: 500, expected_category: 'e_money', expected_method: 'iD' },
          { line: 'iD決済', amount: 738, expected_category: 'e_money' },
          { line: 'PayPay支払', amount: 740, expected_category: 'qr_payment' },
          { line: '楽天ペイ決済', amount: 750, expected_category: 'qr_payment' },
          { line: 'VISA Credit', amount: 760, expected_category: 'credit_card' },
          { line: 'Master Card支払', amount: 770, expected_category: 'credit_card' },
          { line: 'Debit Card', amount: 780, expected_category: 'debit_card' }
        ]

        cases.each do |example|
          ocr_result[:candidates][:payment_method_text] = example[:line]
          ocr_result[:candidates][:payments] = []
          ocr_result[:candidates][:total_amount] = example[:amount]
          ocr_result[:lines] = [
            '合計',
            "¥#{example[:amount]}",
            example[:line],
            "¥#{example[:amount]}"
          ]

          params = described_class.call(ocr_result: ocr_result, ai_result: nil)

          aggregate_failures(example[:line]) do
            expect(params[:receipt_attributes][:payment_method]).to eq(example[:expected_category])
            expect(params[:receipt_payments_attributes]).to contain_exactly(
              include(method: example[:expected_method] || example[:line], amount: example[:amount])
            )
          end
        end
      end

      it '単語内部のidをiD支払として扱わない' do
        %w[sivendidolo middle guideline].each do |noise|
          ocr_result[:candidates][:payment_method_text] = nil
          ocr_result[:candidates][:payments] = []
          ocr_result[:candidates][:total_amount] = 500
          ocr_result[:lines] = [
            "#{noise} 500"
          ]

          params = described_class.call(ocr_result: ocr_result, ai_result: nil)

          aggregate_failures(noise) do
            expect(params[:receipt_attributes][:payment_method]).not_to eq('e_money')
            expect(params[:receipt_payments_attributes]).to eq([])
          end
        end
      end

      it '店名・住所・各種番号行の数字をpayment amountとして扱わない' do
        noise_lines = [
          'サンプル町5丁目店',
          '東京都サンプル区田柄5丁目26-1',
          '登録番号 T1234567890123',
          'TEL 03-3970-6016',
          '伝票番号 200-205-217-3365',
          'カード番号 ****1234',
          '会員番号 ****1234',
          'レジ #2',
          '処理番号 319417776',
          '承認番号 312615',
          '取引番号 987654'
        ]

        noise_lines.each do |noise_line|
          ocr_result[:candidates][:payment_method_text] = 'paypay'
          ocr_result[:candidates][:payments] = []
          ocr_result[:candidates][:total_amount] = 500
          ocr_result[:lines] = [
            'paypay支払',
            noise_line
          ]

          params = described_class.call(ocr_result: ocr_result, ai_result: nil)

          aggregate_failures(noise_line) do
            expect(params[:receipt_attributes][:payment_method]).to eq('qr_payment')
            expect(params[:receipt_payments_attributes]).to eq([])
          end
        end
      end

      it 'OCRノイズと店名数字で偽paymentを作らずキャッシュレス還元とPayPay支払を分けて保存する' do
        ocr_result[:candidates][:payment_method_text] = 'paypay'
        ocr_result[:candidates][:payments] = []
        ocr_result[:candidates][:total_amount] = 255
        ocr_result[:candidates][:adjustment_candidates] = [
          {
            source_text: 'キャッシュレス還元額',
            amount: 5,
            sign_hint: 'discount',
            source_line_index: 3,
            confidence: 0.95
          }
        ]
        ocr_result[:lines] = [
          'サンプルマート',
          'sivendidolo ros',
          'サンプル町5丁目店',
          'キャッシュレス還元額',
          '-5',
          'paypay支払',
          '¥250'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          expect(params[:receipt_attributes][:payment_method]).to eq('qr_payment')
          expect(params[:receipt_payments_attributes]).to contain_exactly(
            include(method: 'paypay支払', amount: 250)
          )
          expect(params[:receipt_payments_attributes].sum { |payment| payment[:amount].to_i }).to eq(250)
          expect(params[:receipt_adjustments_attributes]).to contain_exactly(
            include(label: 'キャッシュレス還元額', amount: 5, sign: 'discount')
          )
        end
      end

      it '広告や対応ブランド一覧だけではrepresentative payment_methodやreceipt_paymentsを作らない' do
        ocr_result[:candidates][:payment_method_text] = nil
        ocr_result[:candidates][:payments] = []
        ocr_result[:candidates][:total_amount] = 1_280
        ocr_result[:lines] = [
          'サンプルストア',
          'PayPay使えます',
          '電子マネー対応',
          '各種クレジット取扱',
          '合計',
          '¥1,280'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          expect(params[:receipt_attributes][:payment_method]).to be_nil
          expect(params[:receipt_payments_attributes]).to eq([])
        end
      end

      it 'カードブランド行の括弧内コードを支払金額として扱わない' do
        ocr_result[:candidates][:payment_method_text] = 'Mastercard'
        ocr_result[:candidates][:payments] = []
        ocr_result[:candidates][:total_amount] = 1_510
        ocr_result[:lines] = [
          'クレジットカード売上票',
          'カード会社',
          'Mastercard(701)',
          '伝票番号',
          '34593',
          '端末番号',
          '30677-200-13077',
          '承認番号',
          '312615'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          expect(params[:receipt_attributes][:payment_method]).to eq('credit_card')
          expect(params[:receipt_payments_attributes]).to eq([])
        end
      end

      it 'クレジット支払行の近傍金額をreceipt total一致で保存する' do
        ocr_result[:candidates][:payment_method_text] = 'クレジット'
        ocr_result[:candidates][:payments] = []
        ocr_result[:candidates][:total_amount] = 1_510
        ocr_result[:lines] = [
          '合計',
          '¥1,510',
          'クレジット',
          '¥1,510',
          'カード会社',
          'Mastercard(701)'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          # 検算: 購入合計 1,510 とクレジット行の次行金額 1,510 が一致する。
          expect(params[:receipt_attributes][:payment_method]).to eq('credit_card')
          expect(params[:receipt_payments_attributes]).to contain_exactly(
            include(method: 'クレジット', amount: 1_510)
          )
        end
      end

      it 'カード売上票の金額ラベル近傍からreceipt total一致の支払額を補完する' do
        ocr_result[:candidates][:payment_method_text] = 'Mastercard'
        ocr_result[:candidates][:payments] = []
        ocr_result[:candidates][:total_amount] = 1_510
        ocr_result[:lines] = [
          'クレジットカード売上票',
          'カード会社',
          'Mastercard(701)',
          '伝票番号',
          '34593',
          '端末番号',
          '30677-200-13077',
          '金額',
          '¥1,510',
          '合計金額',
          '¥1,510',
          '承認番号',
          '312615'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          # 検算: カード会社コード 701 ではなく、金額/合計金額ラベルの 1,510 を支払額にする。
          expect(params[:receipt_attributes][:payment_method]).to eq('credit_card')
          expect(params[:receipt_payments_attributes]).to contain_exactly(
            include(method: 'Mastercard', amount: 1_510)
          )
        end
      end

      it '商品券系はAI adjustmentではなくpaymentへ寄せて電子マネーとの複数支払にする' do
        ocr_result[:candidates][:payment_method_text] = '商品券'
        ocr_result[:candidates][:payments] = []
        ocr_result[:candidates][:total_amount] = 1_872
        ocr_result[:lines] = [
          '合 計',
          '¥1,872',
          '店換金商品券',
          '¥1,000',
          'QUICPay支払',
          '¥872',
          'お釣り',
          '¥0'
        ]
        ai_result = {
          receipt_attributes: {
            payment_method: 'qr_payment'
          },
          receipt_adjustments_attributes: [
            {
              kind: 'coupon',
              label: '店換金商品券',
              amount: 1_000,
              sign: 'discount',
              source_text: '店換金商品券',
              source_line_index: 2,
              confidence: 0.95,
              needs_review: false,
              review_reasons: []
            }
          ]
        }

        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)

        aggregate_failures do
          # 検算: 商品券 1,000 + QUICPay 872 = 支払合計 1,872。
          expect(params[:receipt_payments_attributes]).to contain_exactly(
            include(method: '店換金商品券', amount: 1_000),
            include(method: 'QUICPay支払', amount: 872)
          )
          expect(params[:receipt_adjustments_attributes]).to eq([])
          expect(params[:receipt_attributes][:payment_method]).to eq('e_money')
        end
      end

      it '現計の直前にあるreceipt totalをcash paymentとして補完し直後の税額を拾わない' do
        ocr_result[:candidates][:payment_method_text] = '現金'
        ocr_result[:candidates][:payments] = []
        ocr_result[:candidates][:total_amount] = 500
        ocr_result[:lines] = [
          '駐車券自家用車等',
          '¥500',
          '10%対象',
          '10%税',
          '¥500',
          '現 計',
          '¥45',
          '(うち消費税等',
          '¥500',
          '¥45)'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          # 検算: receipt total 500 と一致する現計直前の金額を支払額にし、直後の税額45は採用しない。
          expect(params[:receipt_payments_attributes]).to contain_exactly(
            include(method: 'cash', amount: 500)
          )
          expect(params[:receipt_payments_attributes]).not_to include(include(amount: 45))
          expect(params[:receipt_attributes][:payment_method]).to eq('cash')
        end
      end

      it '現計と同じ行にreceipt totalがある通常ケースをcash paymentとして補完する' do
        ocr_result[:candidates][:payment_method_text] = '現金'
        ocr_result[:candidates][:payments] = []
        ocr_result[:candidates][:total_amount] = 500
        ocr_result[:lines] = [
          '合計',
          '¥500',
          '現計 ¥500'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          expect(params[:receipt_payments_attributes]).to contain_exactly(
            include(method: 'cash', amount: 500)
          )
          expect(params[:receipt_attributes][:payment_method]).to eq('cash')
        end
      end

      it '現計近傍にreceipt totalがない場合は直後の税額をpaymentにしない' do
        ocr_result[:candidates][:payment_method_text] = '現金'
        ocr_result[:candidates][:payments] = []
        ocr_result[:candidates][:total_amount] = 500
        ocr_result[:lines] = [
          '小計',
          '¥455',
          '10%税',
          '¥45',
          '現 計',
          '¥45'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          expect(params[:receipt_payments_attributes]).to eq([])
          expect(params[:receipt_attributes][:payment_method]).to eq('cash')
        end
      end

      it '同一商品券行が複数ある場合は枚数分を集約してpaymentにする' do
        ocr_result[:candidates][:payment_method_text] = '商品券'
        ocr_result[:candidates][:payments] = []
        ocr_result[:candidates][:total_amount] = 5_184
        ocr_result[:lines] = [
          '合計',
          '¥5,184',
          'サンプル商品券1000',
          '¥1,000',
          'サンプル商品券1000',
          '¥1,000',
          'サンプル商品券1000',
          '¥1,000',
          'サンプル商品券1000',
          '¥1,000',
          'サンプル商品券1000',
          '¥1,000'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          # 検算: 商品券 1,000 x 5 = 5,000。
          expect(params[:receipt_payments_attributes]).to contain_exactly(
            include(method: 'サンプル商品券', amount: 5_000)
          )
          expect(params[:receipt_adjustments_attributes]).to eq([])
          expect(params[:receipt_attributes][:payment_method]).to eq('other')
        end
      end

      it 'AI adjustmentの商品券が1件だけでもOCR上の複数商品券行を優先して集約paymentにする' do
        ocr_result[:candidates][:payment_method_text] = '商品券'
        ocr_result[:candidates][:payments] = []
        ocr_result[:candidates][:total_amount] = 5_184
        ocr_result[:lines] = [
          '合計',
          '¥5,184',
          'サンプル商品券1000',
          '¥1,000',
          'サンプル商品券1000',
          '¥1,000',
          'サンプル商品券1000',
          '¥1,000',
          'サンプル商品券1000',
          '¥1,000',
          'サンプル商品券1000',
          '¥1,000'
        ]
        ai_result = {
          receipt_adjustments_attributes: [
            {
              kind: 'coupon',
              label: 'サンプル商品券1000',
              amount: 1_000,
              sign: 'discount',
              source_text: 'サンプル商品券1000',
              source_line_index: 2,
              confidence: 0.9,
              needs_review: false,
              review_reasons: []
            }
          ]
        }

        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)

        aggregate_failures do
          # 検算: AIの1件ではなく、OCR行の 1,000 x 5 = 5,000 を支払額にする。
          expect(params[:receipt_payments_attributes]).to contain_exactly(
            include(method: 'サンプル商品券', amount: 5_000)
          )
          expect(params[:receipt_adjustments_attributes]).to eq([])
        end
      end

      it '商品券支払の不足額がお預りとお釣りの差額に一致する場合はcash paymentを追加する' do
        ocr_result[:candidates][:payment_method_text] = '商品券'
        ocr_result[:candidates][:payments] = []
        ocr_result[:candidates][:total_amount] = 5_184
        ocr_result[:lines] = [
          '合計',
          '¥5,184',
          'サンプル商品券1000',
          '¥1,000',
          'サンプル商品券1000',
          '¥1,000',
          'サンプル商品券1000',
          '¥1,000',
          'サンプル商品券1000',
          '¥1,000',
          'サンプル商品券1000',
          '¥1,000',
          'お預り',
          '¥200',
          'お釣り',
          '¥16'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          # 検算: 商品券 1,000 x 5 = 5,000, 現金 200 - 16 = 184, 支払合計 5,184。
          expect(params[:receipt_payments_attributes]).to contain_exactly(
            include(method: 'サンプル商品券', amount: 5_000),
            include(method: 'cash', amount: 184)
          )
          expect(params[:receipt_payments_attributes].sum { |payment| payment[:amount].to_i }).to eq(5_184)
          expect(params[:receipt_attributes][:payment_method]).to eq('other')
        end
      end

      it 'お預りとお釣りの差額が不足額と一致しない場合はcash paymentを追加しない' do
        ocr_result[:candidates][:payment_method_text] = '商品券'
        ocr_result[:candidates][:payments] = []
        ocr_result[:candidates][:total_amount] = 5_184
        ocr_result[:lines] = [
          '合計',
          '¥5,184',
          'サンプル商品券1000',
          '¥1,000',
          'サンプル商品券1000',
          '¥1,000',
          'サンプル商品券1000',
          '¥1,000',
          'サンプル商品券1000',
          '¥1,000',
          'サンプル商品券1000',
          '¥1,000',
          'お預り',
          '¥300',
          'お釣り',
          '¥16'
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        aggregate_failures do
          expect(params[:receipt_payments_attributes]).to contain_exactly(
            include(method: 'サンプル商品券', amount: 5_000)
          )
          expect(params[:receipt_payments_attributes]).not_to include(include(method: 'cash'))
        end
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

      it '商品券のみでは payment_method を other にする' do
        ocr_result[:candidates][:payment_method_text] = nil
        ocr_result[:candidates][:payments] = [
          { method: '商品券', amount: 1280 }
        ]

        params = described_class.call(ocr_result: ocr_result, ai_result: nil)

        expect(params[:receipt_attributes][:payment_method]).to eq('other')
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

      it '単一税率の対象計と内税額が明細合計に一致する場合はAI item税率を印字税率へ補正する' do
        sample_dining_ocr_result = {
          candidates: {
            store_name: 'サンプルリア',
            total_amount: 3_130,
            tax_amount: 284,
            country_region: 'JPN',
            payment_method_text: 'クレジット',
            items: [
              { raw_text: '海星サラダ', line_total: 350, confidence: 0.979 },
              { raw_text: 'ピリカラチキン', line_total: 300, confidence: 0.981 },
              { raw_text: '香草チキンの前菜', line_total: 280, confidence: 0.981 },
              { raw_text: '青空ドリア', line_total: 300, confidence: 0.982 },
              { raw_text: 'ガーリックパスタ', line_total: 300, confidence: 0.976 },
              { raw_text: '黒ソースパスタ', line_total: 500, confidence: 0.94 },
              { raw_text: 'きのこ野菜ピザ', line_total: 400, confidence: 0.979 },
              { raw_text: 'グリルプレート', line_total: 400, confidence: 0.979 },
              { raw_text: '赤ぶどうドリンク', line_total: 100, confidence: 0.982 },
              { raw_text: 'セットドリンク200', line_total: 200, confidence: 0.978 }
            ],
            tax_details: [
              { description: '内税額', amount: 284 }
            ]
          },
          lines: [
            'サンプルリア',
            'みどりモール店',
            '小計',
            '¥3,130',
            '合計',
            '¥3,130',
            '10%対象計',
            '¥3,130',
            '(内税額',
            '¥284)',
            'クレジット',
            '¥3,130'
          ]
        }
        ai_result = {
          receipt_items_attributes: Array.new(10) do |index|
            { index: index, category: 'food', tax_rate: 0.08, needs_review: false }
          end
        }

        params = described_class.call(ocr_result: sample_dining_ocr_result, ai_result: ai_result)
        tax_detail = params[:receipt_tax_details_attributes].first

        aggregate_failures do
          expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to all(eq(BigDecimal('0.1')))
          expect(tax_detail).to include(
            description: '10%対象',
            rate: BigDecimal('0.1'),
            net_amount: 2_846,
            amount: 284
          )
          expect(params[:tax_rate_correction]).to include(
            reason: 'single_tax_detail_total_matches_receipt_total',
            source: 'printed_tax_detail',
            rate: '0.1',
            item_count: 10
          )
        end
      end

      it 'AI item税率が既に印字税率と一致する場合も単一税率の対象計からTaxDetailsを復元する' do
        sample_dining_ocr_result = {
          candidates: {
            store_name: 'サンプルリア',
            total_amount: 3_130,
            tax_amount: 284,
            country_region: 'JPN',
            items: [
              { raw_text: '海星サラダ', line_total: 350, confidence: 0.979 },
              { raw_text: 'ピリカラチキン', line_total: 300, confidence: 0.981 },
              { raw_text: '香草チキンの前菜', line_total: 280, confidence: 0.981 },
              { raw_text: '青空ドリア', line_total: 300, confidence: 0.982 },
              { raw_text: 'ガーリックパスタ', line_total: 300, confidence: 0.976 },
              { raw_text: '黒ソースパスタ', line_total: 500, confidence: 0.94 },
              { raw_text: 'きのこ野菜ピザ', line_total: 400, confidence: 0.979 },
              { raw_text: 'グリルプレート', line_total: 400, confidence: 0.979 },
              { raw_text: '赤ぶどうドリンク', line_total: 100, confidence: 0.982 },
              { raw_text: 'セットドリンク200', line_total: 200, confidence: 0.978 }
            ],
            tax_details: [
              { description: '内税額', amount: 284 }
            ]
          },
          lines: [
            '10%対象計',
            '¥3,130',
            '(内税額',
            '¥284)'
          ]
        }
        ai_result = {
          receipt_items_attributes: Array.new(10) do |index|
            { index: index, category: 'food', tax_rate: 0.1, needs_review: false }
          end
        }

        params = described_class.call(ocr_result: sample_dining_ocr_result, ai_result: ai_result)
        tax_detail = params[:receipt_tax_details_attributes].first

        aggregate_failures do
          expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to all(eq(BigDecimal('0.1')))
          expect(tax_detail).to include(rate: BigDecimal('0.1'), net_amount: 2_846, amount: 284)
          expect(params[:tax_rate_correction]).to be_nil
        end
      end

      it '単一税率の対象計が明細合計に一致しない場合はAI item税率を自動補正しない' do
        mismatched_items_ocr_result = {
          candidates: {
            store_name: 'サンプルリア',
            total_amount: 3_130,
            tax_amount: 284,
            country_region: 'JPN',
            items: [
              { raw_text: '商品A', line_total: 1_000, confidence: 0.95 },
              { raw_text: '商品B', line_total: 1_000, confidence: 0.95 },
              { raw_text: '商品C', line_total: 1_000, confidence: 0.95 }
            ],
            tax_details: [
              { description: '内税額', amount: 284 }
            ]
          },
          lines: [
            '10%対象計',
            '¥3,130',
            '(内税額',
            '¥284)'
          ]
        }
        ai_result = {
          receipt_items_attributes: [
            { index: 0, category: 'food', tax_rate: 0.08, needs_review: false },
            { index: 1, category: 'food', tax_rate: 0.08, needs_review: false },
            { index: 2, category: 'food', tax_rate: 0.08, needs_review: false }
          ]
        }

        params = described_class.call(ocr_result: mismatched_items_ocr_result, ai_result: ai_result)

        aggregate_failures do
          expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to all(eq(BigDecimal('0.08')))
          expect(params[:receipt_tax_details_attributes].first).to include(rate: BigDecimal('0.1'), net_amount: 2_846, amount: 284)
          expect(params[:tax_rate_correction]).to be_nil
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

      it 'OCR行の軽減税率markerと税率別対象額が一致する場合だけ複数明細の税率を補正する' do
        mixed_script_receipt = {
          candidates: {
            store_name: '中央南三丁目店',
            total_amount: 844,
            tax_amount: 70,
            country_region: 'JPN',
            payment_method_text: '現金',
            items: [
              { raw_text: '商品A', price: 151, quantity: 1, line_total: 151, confidence: 0.95 },
              { raw_text: '商品B', price: 178, quantity: 1, line_total: 178, confidence: 0.95 },
              { raw_text: '商品C', price: 155, quantity: 1, line_total: 155, confidence: 0.95 },
              { raw_text: '商品D', price: 360, quantity: 1, line_total: 360, confidence: 0.95 }
            ],
            payments: [],
            tax_details: [
              { description: '内消費税等', amount: 70 }
            ]
          },
          lines: [
            'SampleMart',
            '中央南三丁目店',
            '商品A',
            '領',
            '収',
            '証',
            '¥151軽',
            '商品B',
            '¥178軽',
            '商品C',
            '¥155',
            '商品D',
            '¥360',
            '合 計',
            '¥844',
            '(10%対象',
            '¥515)',
            '( 8%対象',
            '¥329)',
            '(内消費税等',
            '¥70)',
            'お 預 り',
            '¥1,044',
            'お',
            '釣',
            '¥200'
          ]
        }
        ai_result = {
          receipt_attributes: {
            store_name: '中央南三丁目店',
            payment_method: 'cash'
          },
          receipt_items_attributes: [
            { index: 0, category: 'food', tax_rate: 0.08, needs_review: false },
            { index: 1, category: 'food', tax_rate: 0.08, needs_review: false },
            { index: 2, category: 'food', tax_rate: 0.08, needs_review: false },
            { index: 3, category: 'food', tax_rate: 0.08, needs_review: false }
          ]
        }

        params = described_class.call(ocr_result: mixed_script_receipt, ai_result: ai_result)

        aggregate_failures do
          # 検算: 151 + 178 = 329(8%対象), floor(329 * 8 / 108) = 24, net = 305。
          # 検算: 155 + 360 = 515(10%対象), floor(515 * 10 / 110) = 46, net = 469。
          # 検算: 税込合計 329 + 515 = 844, 税額 24 + 46 = 70, お預り1044 - お釣り200 = 現金844。
          expect(params[:receipt_attributes][:store_name]).to eq('SampleMart 中央南三丁目店')
          expect(params[:receipt_items_attributes].pluck(:raw_text, :line_total, :tax_rate)).to eq([
            [ '商品A', 151, BigDecimal('0.08') ],
            [ '商品B', 178, BigDecimal('0.08') ],
            [ '商品C', 155, BigDecimal('0.1') ],
            [ '商品D', 360, BigDecimal('0.1') ]
          ])
          expect(params[:receipt_tax_details_attributes]).to contain_exactly(
            include(description: '8%対象', rate: BigDecimal('0.08'), net_amount: 305, amount: 24),
            include(description: '10%対象', rate: BigDecimal('0.1'), net_amount: 469, amount: 46)
          )
          expect(params[:receipt_payments_attributes]).to contain_exactly(
            include(method: 'cash', amount: 844)
          )
          expect(params[:tax_rate_correction]).to include(
            reason: 'tax_marker_group_amount_match',
            source: 'printed_tax_detail',
            item_count: 2
          )
        end
      end

      it '軽減税率markerの明細合計が税率別対象額に一致しない場合は複数明細の税率を補正しない' do
        mismatched_marker_receipt = {
          candidates: {
            store_name: 'Sample Store',
            total_amount: 844,
            tax_amount: 70,
            items: [
              { raw_text: '商品A', line_total: 151 },
              { raw_text: '商品B', line_total: 178 },
              { raw_text: '商品C', line_total: 155 },
              { raw_text: '商品D', line_total: 360 }
            ],
            tax_details: [
              { description: '8%対象', rate: 8, net_amount: 306, amount: 24 },
              { description: '10%対象', rate: 10, net_amount: 468, amount: 46 }
            ]
          },
          lines: [
            '商品A',
            '¥151軽',
            '商品B',
            '¥178',
            '商品C',
            '¥155',
            '商品D',
            '¥360'
          ]
        }

        params = described_class.call(ocr_result: mismatched_marker_receipt, ai_result: nil)

        aggregate_failures do
          expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to all(be_nil)
          expect(params[:tax_rate_correction]).to be_nil
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

      it 'AIがブランド名だけを返した場合でも印字された場所名を補って保存店舗名にする' do
        branch_ocr_result = ocr_result.deep_merge(
          candidates: {
            store_name: 'サンプル食堂',
            store_address: '東京都渋谷区道玄坂1-2-3',
            total_amount: 1510,
            items: [],
            tax_details: []
          },
          lines: [
            'サンプル食堂',
            '株式会社サンプル食堂',
            'サンプル通り',
            '東京都渋谷区道玄坂1-2-3',
            'お客様相談室 0120-498-007',
            '登録番号:t2010401093920'
          ]
        )
        branch_ai_result = {
          receipt_attributes: {
            store_name: 'サンプル食堂'
          },
          receipt_items_attributes: []
        }

        params = described_class.call(ocr_result: branch_ocr_result, ai_result: branch_ai_result)

        expect(params[:receipt_attributes][:store_name]).to eq('サンプル食堂 サンプル通り')
      end

      it '店舗名表記ポリシーとして顧客向けブランドと支店・場所名だけを保存店舗名にする' do
        branch_ocr_result = ocr_result.deep_merge(
          candidates: {
            store_name: '中央南三丁目店',
            store_address: '東京都国分寺市サンプル1-2-3',
            total_amount: 844,
            items: [],
            tax_details: []
          },
          lines: [
            'SampleMart',
            '中央南三丁目店',
            'Managed by',
            'Sample Retail LLC',
            '東京都国分寺市サンプル1-2-3',
            '領収証'
          ]
        )
        branch_ai_result = {
          receipt_attributes: {
            store_name: '中央南三丁目店'
          },
          receipt_items_attributes: []
        }

        params = described_class.call(ocr_result: branch_ocr_result, ai_result: branch_ai_result)

        expect(params[:receipt_attributes][:store_name]).to eq('SampleMart 中央南三丁目店')
      end

      it 'AIが英字ロゴとローカル完結店舗名の重複結合を返した場合はローカル店舗名へ寄せる' do
        local_complete_ocr_result = ocr_result.deep_merge(
          candidates: {
            store_name: 'SampleBrand サンプルブランド東京中央店',
            store_address: '東京都中央区サンプル1-2-3',
            country_region: 'JPN',
            total_amount: 100,
            items: [],
            tax_details: []
          },
          lines: [
            'SampleBrand',
            'サンプルブランド東京中央店',
            'TEL 000-0000-0000',
            '領収証'
          ]
        )
        local_complete_ai_result = {
          receipt_attributes: {
            store_name: 'SampleBrand サンプルブランド東京中央店'
          },
          receipt_items_attributes: []
        }

        params = described_class.call(ocr_result: local_complete_ocr_result, ai_result: local_complete_ai_result)

        expect(params[:receipt_attributes][:store_name]).to eq('サンプルブランド東京中央店')
      end

      it 'ブランドのみ・施設名・ブランド+locationはOCR表記を保存し未印字suffixを足さない' do
        examples = [
          {
            lines: [ 'SampleMart', 'Receipt' ],
            store_name: 'SampleMart',
            expected: 'SampleMart'
          },
          {
            lines: [ 'サンプル浜公園駐車場', '領収証' ],
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
          store_ocr_result = ocr_result.deep_merge(
            candidates: {
              store_name: example[:store_name],
              total_amount: 100,
              items: [],
              tax_details: []
            },
            lines: example[:lines]
          )
          store_ai_result = {
            receipt_attributes: {
              store_name: example[:store_name]
            },
            receipt_items_attributes: []
          }

          params = described_class.call(ocr_result: store_ocr_result, ai_result: store_ai_result)

          aggregate_failures(example[:expected]) do
            expect(params[:receipt_attributes][:store_name]).to eq(example[:expected])
            expect(params[:receipt_attributes][:store_name]).not_to eq("#{example[:expected]} Store")
            expect(params[:receipt_attributes][:store_name]).not_to eq("#{example[:expected]} Branch")
          end
        end
      end

      it 'AIが壊れたOCRブランド名を返した場合はoperator法人名からブランド名を復元する' do
        broken_brand_ocr_result = ocr_result.deep_merge(
          candidates: {
            store_name: '小乐 サンプル通り',
            store_address: '東京都渋谷区道玄坂1-2-3',
            total_amount: 1391,
            items: [],
            tax_details: []
          },
          lines: [
            '小乐',
            '株式会社サンプル食堂',
            'サンプル通り',
            '東京都渋谷区道玄坂1-2-3',
            'お客様相談室',
            '0120-498-007',
            '登録番号:t2010401093920'
          ]
        )
        broken_brand_ai_result = {
          receipt_attributes: {
            store_name: '小乐 サンプル通り'
          },
          receipt_items_attributes: []
        }

        params = described_class.call(ocr_result: broken_brand_ocr_result, ai_result: broken_brand_ai_result)

        expect(params[:receipt_attributes][:store_name]).to eq('サンプル食堂 サンプル通り')
      end

      it 'operator法人名だけでは法人格除去後のブランド名へ自動置換しない' do
        operator_only_ocr_result = ocr_result.deep_merge(
          candidates: {
            store_name: '株式会社サンプル食堂',
            total_amount: 500,
            items: [],
            tax_details: []
          },
          lines: [
            '株式会社サンプル食堂',
            '領収証',
            '合計 ¥500'
          ]
        )
        operator_only_ai_result = {
          receipt_attributes: {
            store_name: '株式会社サンプル食堂'
          },
          receipt_items_attributes: []
        }

        params = described_class.call(ocr_result: operator_only_ocr_result, ai_result: operator_only_ai_result)

        expect(params[:receipt_attributes][:store_name]).to eq('株式会社サンプル食堂')
      end

      it '施設内店舗の場所名を補い、業態説明行は保存店舗名へ含めない' do
        facility_ocr_result = ocr_result.deep_merge(
          candidates: {
            store_name: 'サンプルレストラン',
            total_amount: 3480,
            items: [],
            tax_details: []
          },
          lines: [
            'イタリアンワイン&カフェレストラン',
            'サンプルレストラン',
            'サンプルモール渋谷',
            'tel 03-0000-0000',
            '領収証'
          ]
        )
        facility_ai_result = {
          receipt_attributes: {
            store_name: 'サンプルレストラン'
          },
          receipt_items_attributes: []
        }

        params = described_class.call(ocr_result: facility_ocr_result, ai_result: facility_ai_result)

        expect(params[:receipt_attributes][:store_name]).to eq('サンプルレストラン サンプルモール渋谷')
      end

      it 'ロゴ由来の孤立1文字を英字ブランドへ前置しない' do
        logo_fragment_ocr_result = ocr_result.deep_merge(
          candidates: {
            store_name: 'Sample Life Market',
            total_amount: 1288,
            items: [],
            tax_details: []
          },
          lines: [
            'プ',
            'Sample Life Market',
            'サンプルライフマーケット 恵比寿店',
            '東京都渋谷区サンプル1-2-3',
            'サンプルプラザビルB1F',
            '領収証'
          ]
        )
        logo_fragment_ai_result = {
          receipt_attributes: {
            store_name: 'Sample Life Market'
          },
          receipt_items_attributes: []
        }

        params = described_class.call(ocr_result: logo_fragment_ocr_result, ai_result: logo_fragment_ai_result)

        aggregate_failures do
          expect(params[:receipt_attributes][:store_name]).to eq('Sample Life Market')
          expect(params[:receipt_attributes][:store_name]).not_to start_with('プ ')
        end
      end

      it 'ロゴ由来の孤立1文字を日本語の完全な店舗名へ前置しない' do
        logo_fragment_ocr_result = ocr_result.deep_merge(
          candidates: {
            store_name: 'Sample Life Market',
            total_amount: 1288,
            items: [],
            tax_details: []
          },
          lines: [
            'プ',
            'Sample Life Market',
            'サンプルライフマーケット 恵比寿店',
            '東京都渋谷区サンプル1-2-3',
            'サンプルプラザビルB1F',
            '領収証'
          ]
        )
        logo_fragment_ai_result = {
          receipt_attributes: {
            store_name: 'サンプルライフマーケット 恵比寿店'
          },
          receipt_items_attributes: []
        }

        params = described_class.call(ocr_result: logo_fragment_ocr_result, ai_result: logo_fragment_ai_result)

        aggregate_failures do
          expect(params[:receipt_attributes][:store_name]).to eq('サンプルライフマーケット 恵比寿店')
          expect(params[:receipt_attributes][:store_name]).not_to start_with('プ ')
        end
      end

      it '記号始まりの短いロゴ片をAIの自然な店舗名へ前置しない' do
        logo_fragment_ocr_result = ocr_result.deep_merge(
          candidates: {
            store_name: '/smp サンプル中央店',
            total_amount: 100,
            items: [],
            tax_details: []
          },
          lines: [
            '/smp',
            'サンプル中央店',
            'TEL 000-0000-0000',
            '領収証'
          ]
        )
        logo_fragment_ai_result = {
          receipt_attributes: {
            store_name: 'サンプル中央店'
          },
          receipt_items_attributes: []
        }

        params = described_class.call(ocr_result: logo_fragment_ocr_result, ai_result: logo_fragment_ai_result)

        aggregate_failures do
          expect(params[:receipt_attributes][:store_name]).to eq('サンプル中央店')
          expect(params[:receipt_attributes][:store_name]).not_to start_with('/smp ')
        end
      end

      it 'AIの自然な店舗名へ販促文や営業時間案内を追記しない' do
        message_line_ocr_result = ocr_result.deep_merge(
          candidates: {
            store_name: 'プロの品質とプロの価格 001001東京中央店',
            total_amount: 500,
            items: [],
            tax_details: []
          },
          lines: [
            'プロの品質とプロの価格',
            'サンプルスーパー 東京中央店',
            '毎日安い!この価格!',
            '営業時間AM9:00〜PM9:00',
            '001001東京中央店',
            '領収証'
          ]
        )
        message_line_ai_result = {
          receipt_attributes: {
            store_name: 'サンプルスーパー 東京中央店'
          },
          receipt_items_attributes: []
        }

        params = described_class.call(ocr_result: message_line_ocr_result, ai_result: message_line_ai_result)

        expect(params[:receipt_attributes][:store_name]).to eq('サンプルスーパー 東京中央店')
      end

      it 'AIが自然なブランド+支店名を返している場合は後続候補を追加しない' do
        complete_ai_ocr_result = ocr_result.deep_merge(
          candidates: {
            store_name: 'サンプルスーパー 東京中央店',
            total_amount: 500,
            items: [],
            tax_details: []
          },
          lines: [
            'サンプルスーパー 東京中央店',
            '毎日安い!この価格!',
            '営業時間AM9:00〜PM9:00',
            '領収証'
          ]
        )
        complete_ai_result = {
          receipt_attributes: {
            store_name: 'サンプルスーパー 東京中央店'
          },
          receipt_items_attributes: []
        }

        params = described_class.call(ocr_result: complete_ai_ocr_result, ai_result: complete_ai_result)

        expect(params[:receipt_attributes][:store_name]).to eq('サンプルスーパー 東京中央店')
      end

      it 'AIがブランド名だけを返した場合はOCR上の支店名を補完する' do
        brand_only_ocr_result = ocr_result.deep_merge(
          candidates: {
            store_name: 'SampleMart',
            total_amount: 500,
            items: [],
            tax_details: []
          },
          lines: [
            'SampleMart',
            '東京中央店',
            '領収証'
          ]
        )
        brand_only_ai_result = {
          receipt_attributes: {
            store_name: 'SampleMart'
          },
          receipt_items_attributes: []
        }

        params = described_class.call(ocr_result: brand_only_ocr_result, ai_result: brand_only_ai_result)

        expect(params[:receipt_attributes][:store_name]).to eq('SampleMart 東京中央店')
      end

      it '1文字の英字ブランドは支店名と組み合わせる' do
        one_letter_brand_ocr_result = ocr_result.deep_merge(
          candidates: {
            store_name: '中央店',
            total_amount: 500,
            items: [],
            tax_details: []
          },
          lines: [
            'Q',
            '中央店',
            '東京都渋谷区サンプル1-2-3'
          ]
        )
        one_letter_brand_ai_result = {
          receipt_attributes: {
            store_name: '中央店'
          },
          receipt_items_attributes: []
        }

        params = described_class.call(ocr_result: one_letter_brand_ocr_result, ai_result: one_letter_brand_ai_result)

        expect(params[:receipt_attributes][:store_name]).to eq('Q 中央店')
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

      it 'multiple_tax_receipt はOCR item行の印字税率を保持する' do
        params = described_class.call(ocr_result: ocr_fixture('multiple_tax_receipt'), ai_result: nil)

        expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to eq([
          BigDecimal('0.08'),
          BigDecimal('0.08'),
          BigDecimal('0.08'),
          BigDecimal('0.1'),
          BigDecimal('0.1'),
          BigDecimal('0.1')
        ])
      end

      it 'external_tax_receipt はOCR item行の印字税率を保持する' do
        params = described_class.call(ocr_result: ocr_fixture('external_tax_receipt'), ai_result: nil)

        expect(params[:receipt_items_attributes].map { |item| item[:tax_rate] }).to eq([
          BigDecimal('0.08'),
          BigDecimal('0.08'),
          BigDecimal('0.08'),
          BigDecimal('0.08'),
          BigDecimal('0.1')
        ])
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

      it '商品単位割引がitemに保存される場合は同額AI adjustmentを保存しない' do
        ocr_result[:candidates][:items] = [
          { raw_text: '商品A', price: 300, quantity: 2, original_line_total: 600, discount_amount: 300, line_total: 300 },
          { raw_text: '商品B', price: 598, quantity: 2, original_line_total: 1196, discount_amount: 598, line_total: 598 }
        ]
        ocr_result[:lines] = [
          '商品A',
          '600※',
          '(2個 × 単300)',
          '割引',
          '50%',
          '-300',
          '商品B',
          '1,196※',
          '(2個 × 単598)',
          '割引',
          '50%',
          '-598',
          '小計',
          '¥898'
        ]
        ai_result = {
          receipt_adjustments_attributes: [
            { kind: 'receipt_discount', label: '割引 50%', amount: 300, sign: 'discount', source_text: '割引', source_line_index: 2 },
            { kind: 'receipt_discount', label: '割引 50%', amount: 598, sign: 'discount', source_text: '割引', source_line_index: 8 }
          ]
        }

        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)

        aggregate_failures do
          # 検算: 商品A 600 - 300 = 300、商品B 1,196 - 598 = 598。割引は明細内で表現済み。
          expect(params[:receipt_items_attributes].pluck(:raw_text, :discount_amount, :line_total)).to eq([
            [ '商品A', 300, 300 ],
            [ '商品B', 598, 598 ]
          ])
          expect(params[:receipt_adjustments_attributes]).to eq([])
        end
      end

      it 'レシート全体値引きは商品割引と同額でもreceipt adjustmentとして残す' do
        ocr_result[:candidates][:items] = [
          { raw_text: '商品A', price: 300, quantity: 2, original_line_total: 600, discount_amount: 300, line_total: 300 },
          { raw_text: '商品B', line_total: 700 }
        ]
        ocr_result[:lines] = [
          '商品A',
          '600',
          '割引',
          '50%',
          '-300',
          '商品B',
          '700',
          '小計',
          '¥1,000',
          '会員値引',
          '-300',
          '合計',
          '¥700'
        ]
        ai_result = {
          receipt_adjustments_attributes: [
            { kind: 'receipt_discount', label: '会員値引', amount: 300, sign: 'discount', source_text: '会員値引', source_line_index: 9 }
          ]
        }

        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)

        expect(params[:receipt_adjustments_attributes]).to contain_exactly(
          include(kind: 'receipt_discount', label: '会員値引', amount: 300, sign: 'discount')
        )
      end

      it '商品単位割引とレシート全体値引きが混在しても全体値引きだけをadjustmentに残す' do
        ocr_result[:candidates][:items] = [
          { raw_text: '商品A', price: 300, quantity: 2, original_line_total: 600, discount_amount: 300, line_total: 300 },
          { raw_text: '商品B', line_total: 700 }
        ]
        ocr_result[:lines] = [
          '商品A',
          '600',
          '(2個 × 単300)',
          '割引',
          '50%',
          '-300',
          '商品B',
          '700',
          '小計',
          '¥1,000',
          'クーポン値引',
          '-100',
          '合計',
          '¥900'
        ]
        ai_result = {
          receipt_adjustments_attributes: [
            { kind: 'receipt_discount', label: '割引 50%', amount: 300, sign: 'discount', source_text: '割引', source_line_index: 2 },
            { kind: 'coupon', label: 'クーポン値引', amount: 100, sign: 'discount', source_text: 'クーポン値引', source_line_index: 10 }
          ]
        }

        params = described_class.call(ocr_result: ocr_result, ai_result: ai_result)

        aggregate_failures do
          # 検算: 商品A 600 - 300 = 300、商品B 700、クーポン100円。receipt adjustmentはクーポンのみ。
          expect(params[:receipt_items_attributes].first).to include(discount_amount: 300, line_total: 300)
          expect(params[:receipt_adjustments_attributes]).to contain_exactly(
            include(kind: 'coupon', label: 'クーポン値引', amount: 100, sign: 'discount')
          )
        end
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
