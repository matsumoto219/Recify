require 'rails_helper'

RSpec.describe ReceiptPayment do
  it '1レシートあたりの支払い行数を固定上限までにする' do
    stub_const("#{described_class}::MAX_PER_RECEIPT", 1)
    receipt = create(:receipt)
    receipt.receipt_payments.create!(method: 'Cash', amount: 100)

    payment = receipt.receipt_payments.build(method: 'CreditCard', amount: 200)

    aggregate_failures do
      expect(payment).not_to be_valid
      expect(payment.errors.of_kind?(:receipt, :receipt_payments_limit_exceeded)).to be(true)
    end
  end

  it '他レシートの支払い行数は上限判定へ影響しない' do
    stub_const("#{described_class}::MAX_PER_RECEIPT", 1)
    create(:receipt).receipt_payments.create!(method: 'Cash', amount: 100)
    receipt = create(:receipt)

    payment = receipt.receipt_payments.build(method: 'Cash', amount: 100)

    expect(payment).to be_valid
  end
end
