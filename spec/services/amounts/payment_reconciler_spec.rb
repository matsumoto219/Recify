require 'rails_helper'

RSpec.describe Amounts::PaymentReconciler do
  it '支払行も支払調整もない場合は照合済みではなく未観測として返す' do
    result = described_class.new(
      payments: [],
      purchase_total: 1_000,
      payment_adjustment_total: 0
    ).call

    expect(result).to include(
      final_payment_total: 1_000,
      payment_amount_sum: nil,
      payment_delta: nil,
      matched: nil,
      reconciliation_status: :not_observed,
      warnings: []
    )
  end

  it '支払調整があるのに支払行がない場合は証跡不足として返す' do
    result = described_class.new(
      payments: [],
      purchase_total: 1_000,
      payment_adjustment_total: -100
    ).call

    expect(result).to include(
      final_payment_total: 900,
      payment_amount_sum: nil,
      payment_delta: nil,
      matched: false,
      reconciliation_status: :evidence_missing,
      warnings: [ :payment_amount_mismatch ]
    )
  end

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
      reconciliation_status: :matched,
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
      reconciliation_status: :mismatched,
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

  describe '.suppress_positive_overpayment?' do
    def suppress?(payments:, payment_delta: 100, final_payment_total: 1_000, context: :analysis)
      described_class.suppress_positive_overpayment?(
        payments: payments,
        payment_delta: payment_delta,
        final_payment_total: final_payment_total,
        context: context
      )
    end

    it 'analysisの単一cash/tendered-like過払いだけsuppress対象にする' do
      [
        { method: 'cash', amount: 1_100 },
        { method: 'Cash Tendered', amount: 1_100 },
        { method: 'amount received', amount: 1_100 },
        { method: 'お預かり', amount: 1_100 },
        { method: '現金', amount: 1_100 }
      ].each do |payment|
        expect(suppress?(payments: [ payment ])).to be(true)
      end
    end

    it '非現金の過払いはsuppress対象にしない' do
      %w[credit_card e_money qr_payment gift_card store_credit].each do |method|
        expect(suppress?(payments: [ { method: method, amount: 1_100 } ])).to be(false)
      end
    end

    it '複数支払やexact final payment line併存はsuppress対象にしない' do
      payments = [
        { method: 'cash', amount: 1_000 },
        { method: 'cash_tendered', amount: 1_100 }
      ]

      expect(suppress?(payments: payments, payment_delta: 1_100)).to be(false)
    end

    it 'manual/edit_saveや過払い方向以外はsuppress対象にしない' do
      payment = { method: 'cash', amount: 1_100 }

      aggregate_failures do
        expect(suppress?(payments: [ payment ], context: :manual)).to be(false)
        expect(suppress?(payments: [ payment ], context: :edit_save)).to be(false)
        expect(suppress?(payments: [ payment ], payment_delta: 0)).to be(false)
        expect(suppress?(payments: [ payment ], payment_delta: -100)).to be(false)
      end
    end
  end
end
