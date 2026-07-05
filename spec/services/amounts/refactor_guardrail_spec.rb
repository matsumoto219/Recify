require 'rails_helper'

RSpec.describe 'Amount Engine refactor guardrails' do
  def call_amount_engine(receipt:, items:, tax_details: [], adjustments: [], payments: [], context: :analysis)
    ReceiptAmountService.call(
      receipt: receipt,
      receipt_items: items,
      receipt_tax_details: tax_details,
      receipt_adjustments: adjustments,
      receipt_payments: payments,
      context: context
    )
  end

  it 'AI由来の税率driftがあっても印字税詳細に合う混在候補を採用する' do
    allow(SystemSettings).to receive(:enabled?)
      .with(ReceiptAmountService::TAX_EXCLUDED_PRICE_CONVERSION_SETTING_KEY)
      .and_return(true)

    result = call_amount_engine(
      receipt: {
        total_amount: 1_161,
        subtotal_amount: 1_066,
        tax_amount: 95
      },
      items: [
        { price: 130, quantity: 1, quantity_unit_code: 'each', line_total: 130, tax_rate: BigDecimal('0.08') },
        { price: 140, quantity: 1, quantity_unit_code: 'each', line_total: 140, tax_rate: BigDecimal('0.10') },
        { price: 300, quantity: 1, quantity_unit_code: 'each', line_total: 300, tax_rate: BigDecimal('0.10') },
        { price: 490, quantity: 1, quantity_unit_code: 'each', line_total: 490, tax_rate: BigDecimal('0.10') },
        { price: 50, quantity: 1, quantity_unit_code: 'each', line_total: 50, tax_rate: BigDecimal('0') }
      ],
      tax_details: [
        { rate: BigDecimal('0.08'), net_amount: 270, amount: 21, description: '8%対象' },
        { rate: BigDecimal('0.10'), net_amount: 300, amount: 30, description: '小計（税抜10%）' },
        { rate: BigDecimal('0.10'), net_amount: 820, amount: 74, description: '10%対象' }
      ],
      adjustments: [
        { kind: 'receipt_discount', label: 'キャッシュレス還元額', source_text: 'キャッシュレス還元額 -22', sign: 'discount', amount: 22, source: 'ai' }
      ],
      payments: [
        { method: 'nanaco支払', amount: 1_139 }
      ]
    )

    aggregate_failures do
      expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('mixed_by_tax_rate_group/floor')
      expect(result[:resolved]).to include(subtotal: 1_066, tax: 95, total: 1_161, tax_rate: nil)
      expect(result.dig(:computed, :purchase_total)).to eq(1_161)
      expect(result.dig(:computed, :final_payment_total)).to eq(1_139)
      expect(result.dig(:computed, :payment_adjustment_total)).to eq(-22)
      expect(result.dig(:computed, :items).map { |item| item[:tax_rate] || item['tax_rate'] }).to eq([
        BigDecimal('0.08'),
        BigDecimal('0.08'),
        BigDecimal('0.10'),
        BigDecimal('0.10'),
        BigDecimal('0')
      ])
      expect(result[:review_reasons]).to be_empty
      expect(result[:safe_to_auto_complete]).to be(true)
    end
  end

  it '支払調整はpurchase_totalを変えずfinal_payment_totalにだけ反映する' do
    result = call_amount_engine(
      receipt: {
        total_amount: 1_000,
        tax_amount: 91
      },
      items: [
        { price: 1_000, quantity: 1, quantity_unit_code: 'each', line_total: 1_000, tax_rate: BigDecimal('0.10') }
      ],
      adjustments: [
        { kind: 'point_usage', sign: 'discount', amount: 100 }
      ],
      payments: [
        { method: 'credit_card', amount: 900 }
      ]
    )

    aggregate_failures do
      expect(result[:resolved]).to include(subtotal: 909, tax: 91, total: 1_000, tax_rate: BigDecimal('0.10'))
      expect(result.dig(:computed, :purchase_total)).to eq(1_000)
      expect(result.dig(:computed, :final_payment_total)).to eq(900)
      expect(result.dig(:computed, :purchase_adjustment_total)).to eq(0)
      expect(result.dig(:computed, :payment_adjustment_total)).to eq(-100)
      expect(result[:review_reasons]).to be_empty
      expect(result[:safe_to_auto_complete]).to be(true)
    end
  end

  it '購入調整はpurchase_totalに反映しfinal_payment_totalと一致させる' do
    result = call_amount_engine(
      receipt: {
        total_amount: 900,
        tax_amount: 82
      },
      items: [
        { price: 1_000, quantity: 1, quantity_unit_code: 'each', line_total: 1_000, tax_rate: BigDecimal('0.10') }
      ],
      adjustments: [
        { kind: 'coupon', sign: 'discount', amount: 100, tax_rate: BigDecimal('0.10') }
      ],
      payments: [
        { method: 'credit_card', amount: 900 }
      ]
    )

    aggregate_failures do
      expect(result[:resolved]).to include(subtotal: 818, tax: 82, total: 900, tax_rate: BigDecimal('0.10'))
      expect(result.dig(:computed, :purchase_total)).to eq(900)
      expect(result.dig(:computed, :final_payment_total)).to eq(900)
      expect(result.dig(:computed, :purchase_adjustment_total)).to eq(-100)
      expect(result.dig(:computed, :payment_adjustment_total)).to eq(0)
      expect(result[:review_reasons]).to be_empty
      expect(result[:safe_to_auto_complete]).to be(true)
    end
  end

  it 'snapshotにraw textやprovider detailを含めない' do
    result = call_amount_engine(
      receipt: {
        total_amount: 1_000,
        tax_amount: 91,
        provider_raw_response: '保存しない'
      },
      items: [
        { raw_text: '保存しない商品OCR行', price: 1_000, quantity: 1, line_total: 1_000, tax_rate: BigDecimal('0.10') }
      ],
      tax_details: [
        { rate: BigDecimal('0.10'), net_amount: 909, amount: 91, description: '保存しない税詳細説明' }
      ],
      adjustments: [
        { kind: 'point_usage', sign: 'discount', amount: 100, source_text: '保存しない調整元行' }
      ],
      payments: [
        { method: 'credit_card', amount: 900, provider_raw_response: '保存しない支払raw' }
      ]
    )

    snapshot = ReceiptAmountService.calculation_profile_snapshot(result)
    serialized = JSON.generate(snapshot)

    aggregate_failures do
      expect(snapshot.dig(:amount_engine, :schema_version)).to eq(1)
      expect(serialized).not_to include('保存しない商品OCR行')
      expect(serialized).not_to include('保存しない税詳細説明')
      expect(serialized).not_to include('保存しない調整元行')
      expect(serialized).not_to include('provider_raw_response')
    end
  end
end
