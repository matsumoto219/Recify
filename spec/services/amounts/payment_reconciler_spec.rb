require 'rails_helper'

RSpec.describe Amounts::PaymentReconciler do
  it '購入合計と支払調整から最終支払額を照合する' do
    result = described_class.new(
      payments: [
        { method: 'nanaco', amount: 1_139 }
      ],
      purchase_total: 1_161,
      payment_adjustment_total: -22
    ).call

    expect(result).to include(
      purchase_total: 1_161,
      payment_adjustment_total: -22,
      final_payment_total: 1_139,
      payment_amount_sum: 1_139,
      payment_delta: 0,
      matched: true,
      warnings: []
    )
  end

  it '支払合計が最終支払額と違う場合はwarningを返す' do
    result = described_class.new(
      payments: [
        { method: 'cash', amount: 900 }
      ],
      purchase_total: 1_000,
      payment_adjustment_total: 0
    ).call

    expect(result).to include(
      final_payment_total: 1_000,
      payment_amount_sum: 900,
      payment_delta: -100,
      matched: false,
      warnings: [ :payment_amount_mismatch ]
    )
  end

  it '支払合計が最終支払額を上回る場合もwarningを返す' do
    result = described_class.new(
      payments: [
        { method: 'cash', amount: 1_100 }
      ],
      purchase_total: 1_000,
      payment_adjustment_total: 0
    ).call

    expect(result).to include(
      final_payment_total: 1_000,
      payment_amount_sum: 1_100,
      payment_delta: 100,
      matched: false,
      warnings: [ :payment_amount_mismatch ]
    )
  end
end
