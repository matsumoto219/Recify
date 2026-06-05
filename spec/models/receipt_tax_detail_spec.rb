require 'rails_helper'

RSpec.describe ReceiptTaxDetail do
  it '1レシートあたりの税内訳数を固定上限までにする' do
    stub_const("#{described_class}::MAX_PER_RECEIPT", 1)
    receipt = create(:receipt)
    receipt.receipt_tax_details.create!(description: '10%対象', rate: 0.1, amount: 10, net_amount: 100)

    tax_detail = receipt.receipt_tax_details.build(description: '8%対象', rate: 0.08, amount: 8, net_amount: 100)

    aggregate_failures do
      expect(tax_detail).not_to be_valid
      expect(tax_detail.errors.of_kind?(:receipt, :receipt_tax_details_limit_exceeded)).to be(true)
    end
  end

  it '他レシートの税内訳数は上限判定へ影響しない' do
    stub_const("#{described_class}::MAX_PER_RECEIPT", 1)
    create(:receipt).receipt_tax_details.create!(description: '10%対象', rate: 0.1, amount: 10, net_amount: 100)
    receipt = create(:receipt)

    tax_detail = receipt.receipt_tax_details.build(description: '10%対象', rate: 0.1, amount: 10, net_amount: 100)

    expect(tax_detail).to be_valid
  end
end
