require 'rails_helper'

RSpec.describe ReceiptTaxDetail do
  it 'SystemSettingsの税額上限を参照する' do
    create(:system_setting, key: 'limits.receipt_tax_amount_max', value: SystemSettings.stored_value(500))

    tax_detail = build(:receipt).receipt_tax_details.build(description: '10%対象', rate: 0.1, amount: 501, net_amount: 501)

    aggregate_failures do
      expect(tax_detail).not_to be_valid
      expect(tax_detail.errors[:amount]).to be_present
      expect(tax_detail.errors[:net_amount]).to be_present
    end
  end

  it '1レシートあたりの税内訳数をdefault上限までにする' do
    receipt = create(:receipt)
    described_class::MAX_PER_RECEIPT.times do |index|
      receipt.receipt_tax_details.create!(description: "#{index}%対象", rate: 0.1, amount: 10, net_amount: 100)
    end

    tax_detail = receipt.receipt_tax_details.build(description: '8%対象', rate: 0.08, amount: 8, net_amount: 100)

    aggregate_failures do
      expect(described_class.per_receipt_limit).to eq(20)
      expect(tax_detail).not_to be_valid
      expect(tax_detail.errors.of_kind?(:receipt, :receipt_tax_details_limit_exceeded)).to be(true)
    end
  end

  it 'SystemSettingsの税内訳上限を参照する' do
    create(:system_setting, key: 'limits.receipt_tax_details_per_receipt', value: SystemSettings.stored_value(50))
    receipt = create(:receipt)
    50.times do |index|
      receipt.receipt_tax_details.create!(description: "#{index}%対象", rate: 0.1, amount: 10, net_amount: 100)
    end

    tax_detail = receipt.receipt_tax_details.build(description: '8%対象', rate: 0.08, amount: 8, net_amount: 100)

    aggregate_failures do
      expect(described_class.per_receipt_limit).to eq(50)
      expect(tax_detail).not_to be_valid
      expect(tax_detail.errors.of_kind?(:receipt, :receipt_tax_details_limit_exceeded)).to be(true)
    end
  end

  it '上限0なら税内訳を保存不可にする' do
    create(:system_setting, key: 'limits.receipt_tax_details_per_receipt', value: SystemSettings.stored_value(0))
    receipt = create(:receipt)

    tax_detail = receipt.receipt_tax_details.build(description: '8%対象', rate: 0.08, amount: 8, net_amount: 100)

    aggregate_failures do
      expect(tax_detail).not_to be_valid
      expect(tax_detail.errors.of_kind?(:receipt, :receipt_tax_details_limit_exceeded)).to be(true)
    end
  end

  it '他レシートの税内訳数は上限判定へ影響しない' do
    create(:system_setting, key: 'limits.receipt_tax_details_per_receipt', value: SystemSettings.stored_value(1))
    create(:receipt).receipt_tax_details.create!(description: '10%対象', rate: 0.1, amount: 10, net_amount: 100)
    receipt = create(:receipt)

    tax_detail = receipt.receipt_tax_details.build(description: '10%対象', rate: 0.1, amount: 10, net_amount: 100)

    expect(tax_detail).to be_valid
  end
end
