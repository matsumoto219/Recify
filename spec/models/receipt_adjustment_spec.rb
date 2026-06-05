require 'rails_helper'

RSpec.describe ReceiptAdjustment do
  it '商品単位割引をreceipt_adjustmentsのkindとして扱わない' do
    expect(described_class::KINDS).not_to include('item_discount')
  end

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

  it '1レシートあたりの調整行数を設定上限までにする' do
    create(:system_setting, key: 'limits.receipt_adjustments_per_receipt', value: SystemSettings.stored_value(1))
    receipt = create(:receipt)
    create(:receipt_adjustment, receipt: receipt)

    adjustment = build(:receipt_adjustment, receipt: receipt)

    aggregate_failures do
      expect(adjustment).not_to be_valid
      expect(adjustment.errors.of_kind?(:receipt, :receipt_adjustments_limit_exceeded)).to be(true)
    end
  end

  it '調整行上限0では新規調整行を保存不可にする' do
    create(:system_setting, key: 'limits.receipt_adjustments_per_receipt', value: SystemSettings.stored_value(0))

    adjustment = build(:receipt_adjustment, receipt: create(:receipt))

    aggregate_failures do
      expect(adjustment).not_to be_valid
      expect(adjustment.errors.of_kind?(:receipt, :receipt_adjustments_limit_exceeded)).to be(true)
    end
  end

  it 'is destroyed with receipt' do
    receipt = create(:receipt)
    create(:receipt_adjustment, receipt: receipt)

    expect { receipt.destroy! }.to change(described_class, :count).by(-1)
  end
end
