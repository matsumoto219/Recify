require 'rails_helper'

RSpec.describe ReceiptPayment do
  it 'SystemSettingsの支払い額上限を参照する' do
    create(:system_setting, key: 'limits.receipt_payment_amount_max', value: SystemSettings.stored_value(500))

    payment = build(:receipt).receipt_payments.build(method: 'CreditCard', amount: 501)

    aggregate_failures do
      expect(payment).not_to be_valid
      expect(payment.errors[:amount]).to be_present
    end
  end

  it '1レシートあたりの支払い行数をdefault上限までにする' do
    receipt = create(:receipt)
    described_class::MAX_PER_RECEIPT.times do |index|
      receipt.receipt_payments.create!(method: "Payment #{index}", amount: index)
    end

    payment = receipt.receipt_payments.build(method: 'CreditCard', amount: 200)

    aggregate_failures do
      expect(described_class.per_receipt_limit).to eq(20)
      expect(payment).not_to be_valid
      expect(payment.errors.of_kind?(:receipt, :receipt_payments_limit_exceeded)).to be(true)
    end
  end

  it 'SystemSettingsの支払い行上限を参照する' do
    create(:system_setting, key: 'limits.receipt_payments_per_receipt', value: SystemSettings.stored_value(50))
    receipt = create(:receipt)
    50.times do |index|
      receipt.receipt_payments.create!(method: "Payment #{index}", amount: index)
    end

    payment = receipt.receipt_payments.build(method: 'CreditCard', amount: 200)

    aggregate_failures do
      expect(described_class.per_receipt_limit).to eq(50)
      expect(payment).not_to be_valid
      expect(payment.errors.of_kind?(:receipt, :receipt_payments_limit_exceeded)).to be(true)
    end
  end

  it '上限0なら支払い行を保存不可にする' do
    create(:system_setting, key: 'limits.receipt_payments_per_receipt', value: SystemSettings.stored_value(0))
    receipt = create(:receipt)

    payment = receipt.receipt_payments.build(method: 'CreditCard', amount: 200)

    aggregate_failures do
      expect(payment).not_to be_valid
      expect(payment.errors.of_kind?(:receipt, :receipt_payments_limit_exceeded)).to be(true)
    end
  end

  it '他レシートの支払い行数は上限判定へ影響しない' do
    create(:system_setting, key: 'limits.receipt_payments_per_receipt', value: SystemSettings.stored_value(1))
    create(:receipt).receipt_payments.create!(method: 'Cash', amount: 100)
    receipt = create(:receipt)

    payment = receipt.receipt_payments.build(method: 'Cash', amount: 100)

    expect(payment).to be_valid
  end
end
