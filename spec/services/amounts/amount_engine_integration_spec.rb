require 'rails_helper'

RSpec.describe 'Amount Engine integration' do
  def call_amount_engine(receipt:, items:, tax_details: [], adjustments: [], payments: [])
    ReceiptAmountService.call(
      receipt: receipt,
      receipt_items: items,
      receipt_tax_details: tax_details,
      receipt_adjustments: adjustments,
      receipt_payments: payments,
      context: :analysis
    )
  end

  it '2019年サンプルコンビニの税抜/税込/非課税/支払調整混在レシートを候補検算で解決する' do
    result = call_amount_engine(
      receipt: {
        subtotal_amount: 1_390,
        tax_amount: 125,
        total_amount: 1_515
      },
      items: [
        { line_total: 130, tax_rate: BigDecimal('0.08') },
        { line_total: 140, tax_rate: BigDecimal('0.08') },
        { line_total: 300, tax_rate: BigDecimal('0.10') },
        { line_total: 490, tax_rate: BigDecimal('0.10') },
        { line_total: 50, tax_rate: BigDecimal('0') }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 270, amount: 21, description: '8%対象' },
        { rate: BigDecimal('0.10'), net_amount: 300, amount: 30, description: '小計（税抜10%）' },
        { rate: BigDecimal('0.10'), net_amount: 820, amount: 74, description: '10%対象' }
      ],
      adjustments: [
        {
          kind: 'other',
          label: 'キャッシュレス還元額',
          source_text: 'キャッシュレス還元額 -22',
          sign: 'discount',
          amount: 22,
          source: 'ocr'
        }
      ],
      payments: [
        { method: 'nanaco', amount: 1_139 }
      ]
    )

    aggregate_failures do
      # 検算:
      # 8%: 130税抜 -> 140税込, 140税抜 -> 151税込, 税込291 / 税21 / 税抜270
      # 10%: 300税抜 -> 330税込, 490税込, 税込820 / 税 floor(820 * 10 / 110)=74 / 税抜746
      # 0%: 50。購入合計 291 + 820 + 50 = 1,161。支払調整 -22 で final 1,139。
      expect(result[:resolved]).to include(subtotal: 1_066, tax: 95, total: 1_161, tax_rate: nil)
      expect(result.dig(:computed, :final_payment_total)).to eq(1_139)
      expect(result.dig(:computed, :payment_adjustment_total)).to eq(-22)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(1_139)
      expect(result.dig(:computed, :items).map { |item| item['line_total'] || item[:line_total] }).to eq([ 140, 151, 330, 490, 50 ])
      expect(result[:tax_details]).to contain_exactly(
        include(rate: BigDecimal('0.08'), net_amount: 270, amount: 21),
        include(rate: BigDecimal('0.10'), net_amount: 746, amount: 74)
      )
      expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('mixed_by_tax_rate_group/floor')
      expect(result[:blocking_inconsistencies]).to be_empty
      expect(result[:warning_inconsistencies]).to include(:price_tax_inclusion_uncertain)
      expect(result[:review_reasons]).to include('price_tax_inclusion_uncertain')
      expect(result[:needs_review]).to be(true)
    end
  end

  it '2019年サンプルコンビニのOCR descriptionが潰れた再解析データでもlegacyではなく混在候補を採用する' do
    result = call_amount_engine(
      receipt: {
        subtotal_amount: 10,
        tax_amount: 125,
        total_amount: 1_161
      },
      items: [
        { line_total: 130, tax_rate: BigDecimal('0.08') },
        { line_total: 140, tax_rate: BigDecimal('0.08') },
        { line_total: 300, tax_rate: BigDecimal('0.10') },
        { line_total: 490, tax_rate: BigDecimal('0.10') },
        { line_total: 50, tax_rate: BigDecimal('0') }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 270, amount: 21, description: '消費税等' },
        { rate: BigDecimal('0.10'), net_amount: 300, amount: 30, description: '消費税等' },
        { rate: BigDecimal('0.10'), net_amount: 820, amount: 74, description: '内消費税等' }
      ],
      adjustments: [
        {
          kind: 'receipt_discount',
          label: 'キャッシュレス還元額',
          source_text: 'キャッシュレス還元額 -22',
          sign: 'discount',
          amount: 22,
          source: 'ai',
          needs_review: true
        }
      ],
      payments: [
        { method: 'nanaco支払', amount: 1_139 }
      ]
    )

    selected = result.dig(:amount_engine, :selected_candidate)

    aggregate_failures do
      # 検算:
      # 8%: 130税抜 -> 140税込, 140税抜 -> 151税込, gross=291, tax=21。
      # 10%: 300税抜 -> 330税込, 490税込, gross=820, tax=floor(820 * 10 / 110)=74。
      # 0%: 50。purchase_total=291 + 820 + 50 = 1,161。cashless_reward=-22でfinal=1,139。
      expect(result[:resolved]).to include(subtotal: 1_066, tax: 95, total: 1_161, tax_rate: nil)
      expect(result.dig(:amount_engine, :selected_basis)).to eq('mixed_by_tax_rate_group')
      expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('mixed_by_tax_rate_group/floor')
      expect(selected).to include(
        purchase_total: 1_161,
        final_payment_total: 1_139,
        payment_adjustment_total: -22,
        payment_amount_sum: 1_139
      )
      expect(result.dig(:computed, :items).map { |item| item['line_total'] || item[:line_total] }).to eq([ 140, 151, 330, 490, 50 ])
      expect(result[:review_reasons]).to include('price_tax_inclusion_uncertain')
      expect(result[:amount_engine][:candidates].map { |candidate| candidate[:candidate_id] }).to include('mixed_by_tax_rate_group/floor')
    end
  end

  it 'スーパーの複数税率とレシート全体値引きを購入合計として計算する' do
    result = call_amount_engine(
      receipt: { subtotal_amount: 800, tax_amount: 78, total_amount: 878 },
      items: [
        { line_total: 216, tax_rate: BigDecimal('0.08') },
        { line_total: 162, tax_rate: BigDecimal('0.08') },
        { line_total: 550, tax_rate: BigDecimal('0.10') }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 378, amount: 28, description: '8%対象' },
        { rate: BigDecimal('0.10'), net_amount: 550, amount: 50, description: '10%対象' }
      ],
      adjustments: [
        { kind: 'receipt_discount', sign: 'discount', amount: 50, source: 'ocr' }
      ],
      payments: [
        { method: 'cash', amount: 878 }
      ]
    )

    aggregate_failures do
      # 検算: 商品税込 216 + 162 + 550 = 928、購入値引き -50、購入合計 878。
      # 税額は印字税額 28 + 50 = 78、税抜は 878 - 78 = 800。
      expect(result[:resolved]).to include(subtotal: 800, tax: 78, total: 878)
      expect(result.dig(:computed, :purchase_adjustment_total)).to eq(-50)
      expect(result.dig(:computed, :final_payment_total)).to eq(878)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(878)
      expect(result[:needs_review]).to be(false)
    end
  end

  it 'ドラッグストアのクーポン値引きとポイント利用を購入調整/支払調整に分ける' do
    result = call_amount_engine(
      receipt: { subtotal_amount: 1_500, tax_amount: 150, total_amount: 1_650 },
      items: [
        { line_total: 880, tax_rate: BigDecimal('0.10') },
        { line_total: 330, tax_rate: BigDecimal('0.10') },
        { line_total: 540, tax_rate: BigDecimal('0.08') }
      ],
      tax_details: [
        { rate: BigDecimal('0.10'), net_amount: 1_210, amount: 110, description: '10%対象' },
        { rate: BigDecimal('0.08'), net_amount: 540, amount: 40, description: '8%対象' }
      ],
      adjustments: [
        { kind: 'coupon', sign: 'discount', amount: 100, source: 'ocr' },
        { kind: 'point_usage', sign: 'discount', amount: 200, source: 'ocr' }
      ],
      payments: [
        { method: 'credit', amount: 1_450 }
      ]
    )

    aggregate_failures do
      # 検算: 商品税込 1,750、クーポン -100 で購入合計 1,650。
      # ポイント -200 は支払調整なので final は 1,450。
      expect(result[:resolved]).to include(subtotal: 1_500, tax: 150, total: 1_650)
      expect(result.dig(:computed, :purchase_adjustment_total)).to eq(-100)
      expect(result.dig(:computed, :payment_adjustment_total)).to eq(-200)
      expect(result.dig(:computed, :final_payment_total)).to eq(1_450)
      expect(result[:needs_review]).to be(false)
    end
  end

  it '外税レシートではexternal_tax候補を採用する' do
    result = call_amount_engine(
      receipt: { subtotal_amount: 1_000, tax_amount: 100, total_amount: 1_100, tax_rate: BigDecimal('0.10') },
      items: [
        { line_total: 400, tax_rate: BigDecimal('0.10') },
        { line_total: 600, tax_rate: BigDecimal('0.10') }
      ],
      tax_details: [
        { rate: BigDecimal('0.10'), net_amount: 1_000, amount: 100, description: '外税10%' }
      ],
      payments: [
        { method: 'cash', amount: 1_100 }
      ]
    )

    aggregate_failures do
      # 検算: 税抜明細 400 + 600 = 1,000、外税10% = 100、税込合計 1,100。
      expect(result[:resolved]).to include(subtotal: 1_000, tax: 100, total: 1_100, tax_rate: BigDecimal('0.10'))
      expect(result.dig(:amount_engine, :selected_basis)).to eq('external_tax_from_receipt')
      expect(result.dig(:computed, :payment_amount_sum)).to eq(1_100)
      expect(result[:needs_review]).to be(false)
    end
  end

  it '現金と電子マネーの複数支払をfinal_payment_totalと照合する' do
    result = call_amount_engine(
      receipt: { subtotal_amount: 1_061, tax_amount: 100, total_amount: 1_161 },
      items: [
        { line_total: 150, tax_rate: BigDecimal('0.08') },
        { line_total: 130, tax_rate: BigDecimal('0.08') },
        { line_total: 881, tax_rate: BigDecimal('0.10') }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 280, amount: 20, description: '8%対象' },
        { rate: BigDecimal('0.10'), net_amount: 881, amount: 80, description: '10%対象' }
      ],
      payments: [
        { method: 'cash', amount: 500 },
        { method: '電子マネー', amount: 661 }
      ]
    )

    aggregate_failures do
      # 検算: 購入合計 1,161、支払合計 500 + 661 = 1,161。
      expect(result[:resolved]).to include(subtotal: 1_061, tax: 100, total: 1_161)
      expect(result.dig(:computed, :payment_amount_sum)).to eq(1_161)
      expect(result.dig(:computed, :final_payment_total)).to eq(1_161)
      expect(result[:blocking_inconsistencies]).to be_empty
    end
  end

  it 'VAT/GSTの任意税率候補を扱う' do
    vat = call_amount_engine(
      receipt: { subtotal_amount: 100, tax_amount: 20, total_amount: 120 },
      items: [
        { line_total: 120, tax_rate: BigDecimal('0.20') }
      ],
      tax_details: [
        { rate: BigDecimal('0.20'), net_amount: 120, amount: 20, description: 'VAT included 20%' }
      ],
      payments: [
        { method: 'card', amount: 120 }
      ]
    )

    gst = call_amount_engine(
      receipt: { subtotal_amount: 1_000, tax_amount: 50, total_amount: 1_050 },
      items: [
        { line_total: 1_000, tax_rate: BigDecimal('0.05') }
      ],
      tax_details: [
        { rate: BigDecimal('0.05'), net_amount: 1_000, amount: 50, description: 'GST exclusive 5%' }
      ],
      payments: [
        { method: 'card', amount: 1_050 }
      ]
    )

    aggregate_failures do
      # 検算: VAT内税 120 * 20 / 120 = 20、税抜100。
      expect(vat[:resolved]).to include(subtotal: 100, tax: 20, total: 120)
      # 検算: GST外税 1,000 * 5% = 50、税込1,050。
      expect(gst[:resolved]).to include(subtotal: 1_000, tax: 50, total: 1_050)
      expect(gst.dig(:amount_engine, :selected_basis)).to eq('external_tax_from_receipt')
    end
  end

  it '支払合計がfinal_payment_totalと不一致ならblocking reviewにする' do
    result = call_amount_engine(
      receipt: { total_amount: 1_000 },
      items: [
        { line_total: 1_000 }
      ],
      payments: [
        { method: 'cash', amount: 900 }
      ]
    )

    expect(result[:blocking_inconsistencies]).to include(:payment_amount_mismatch)
    expect(result[:needs_review]).to be(true)
  end
end
