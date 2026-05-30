require 'rails_helper'

RSpec.describe ReceiptAdjustment do
  it 'validates allowlisted kind, sign, and source' do
    adjustment = build(:receipt_adjustment, kind: 'invalid', sign: 'bad', source: 'unknown')

    expect(adjustment).not_to be_valid
  end

  it 'stores amount as an absolute value and exposes signed amount by sign' do
    discount = build(:receipt_adjustment, amount: 980, sign: 'discount')
    surcharge = build(:receipt_adjustment, amount: 550, sign: 'surcharge')

    aggregate_failures do
      expect(discount.signed_amount).to eq(-980)
      expect(surcharge.signed_amount).to eq(550)
    end
  end

  it 'requires review_reasons to be an array' do
    adjustment = build(:receipt_adjustment, review_reasons: 'invalid')

    expect(adjustment).not_to be_valid
  end

  it 'is destroyed with receipt' do
    receipt = create(:receipt)
    create(:receipt_adjustment, receipt: receipt)

    expect { receipt.destroy! }.to change(described_class, :count).by(-1)
  end
end
