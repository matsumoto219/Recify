require 'rails_helper'

RSpec.describe Amounts::PaymentAdjustmentSummary do
  it 'amount_calculation_profileから支払調整と実支払額を返す' do
    receipt = build(
      :receipt,
      total_amount: 1_161,
      amount_calculation_profile: {
        computed: {
          payment_adjustment_total: -22,
          final_payment_total: 1_139
        }
      }
    )

    result = described_class.call(receipt: receipt)

    aggregate_failures do
      # 検算: 購入合計 1,161 + 支払調整 -22 = 実支払額 1,139。
      expect(result.payment_adjustment_total).to eq(-22)
      expect(result.final_payment_total).to eq(1_139)
    end
  end

  it 'profileがない場合は支払調整adjustmentから実支払額を計算する' do
    receipt = build(:receipt, total_amount: 1_161)
    adjustments = [
      {
        kind: 'receipt_discount',
        label: 'キャッシュレス還元額',
        source_text: 'キャッシュレス還元額 -22',
        sign: 'discount',
        amount: 22,
        source: 'ai'
      }
    ]

    result = described_class.call(receipt: receipt, receipt_adjustments: adjustments)

    aggregate_failures do
      # 検算: 購入合計 1,161 + 支払調整 -22 = 実支払額 1,139。
      expect(result.payment_adjustment_total).to eq(-22)
      expect(result.final_payment_total).to eq(1_139)
    end
  end

  it 'computedが欠ける場合はselected candidateの支払調整を使う' do
    receipt = build(
      :receipt,
      total_amount: 1_161,
      amount_calculation_profile: {
        amount_engine: {
          selected_candidate: {
            payment_adjustment_total: -22,
            final_payment_total: 1_139
          }
        }
      }
    )

    result = described_class.call(receipt: receipt)

    aggregate_failures do
      # 検算: 購入合計 1,161 + 支払調整 -22 = 実支払額 1,139。
      expect(result.payment_adjustment_total).to eq(-22)
      expect(result.final_payment_total).to eq(1_139)
    end
  end

  it '支払調整がない場合はnilを返す' do
    receipt = build(
      :receipt,
      total_amount: 1_161,
      amount_calculation_profile: {
        computed: {
          payment_adjustment_total: 0,
          final_payment_total: 1_161
        }
      }
    )

    expect(described_class.call(receipt: receipt)).to be_nil
  end
end
