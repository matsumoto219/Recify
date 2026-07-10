require 'rails_helper'

RSpec.describe ReceiptEditSaveChangeSet do
  let(:receipt) do
    create(
      :receipt,
      status: 'completed',
      subtotal_amount: 91,
      tax_amount: 9,
      total_amount: 100,
      tax_rate: BigDecimal('0.1')
    )
  end

  it 'itemの表示項目だけの変更をpurchase amount変更にしない' do
    item = receipt.receipt_items.create!(
      confirmed_name: '変更前', price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => { 'id' => item.id.to_s, 'confirmed_name' => '変更後' }
        }
      }
    )

    expect(result.purchase_amounts_changed?).to be(false)
  end

  it 'itemのquantity変更をpurchase amount変更にする' do
    item = receipt.receipt_items.create!(
      confirmed_name: '商品', price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => { 'id' => item.id.to_s, 'quantity' => '2' }
        }
      }
    )

    expect(result.purchase_amounts_changed?).to be(true)
  end

  it '購入調整と支払調整の変更を分離する' do
    coupon = receipt.receipt_adjustments.create!(
      kind: 'coupon', amount: 10, sign: 'discount', source: 'manual', needs_review: false
    )
    point = receipt.receipt_adjustments.create!(
      kind: 'point_usage', amount: 20, sign: 'discount', source: 'manual', needs_review: false
    )

    purchase_result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_adjustments_attributes' => {
          '0' => { 'id' => coupon.id.to_s, 'amount' => '15' }
        }
      }
    )
    payment_result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_adjustments_attributes' => {
          '0' => { 'id' => point.id.to_s, 'amount' => '25' }
        }
      }
    )

    aggregate_failures do
      expect(purchase_result.purchase_adjustments_changed).to be(true)
      expect(purchase_result.payment_adjustments_changed).to be(false)
      expect(payment_result.purchase_adjustments_changed).to be(false)
      expect(payment_result.payment_adjustments_changed).to be(true)
    end
  end

  it 'payment-only変更はpurchase amountsをstaleにしない' do
    payment = receipt.receipt_payments.create!(method: '現金', amount: 100)

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_payments_attributes' => {
          '0' => { 'id' => payment.id.to_s, 'amount' => '50' }
        }
      }
    )

    aggregate_failures do
      expect(result.payments_changed).to be(true)
      expect(result.purchase_amounts_changed?).to be(false)
      expect(result.payment_reconciliation_changed?).to be(true)
    end
  end

  it '同じ金額値の再送信を変更扱いにしない' do
    item = receipt.receipt_items.create!(
      confirmed_name: '商品',
      price: 100,
      quantity: 1,
      quantity_unit_code: 'each',
      tax_rate: BigDecimal('0.1'),
      line_total: 100
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'subtotal_amount' => '91',
        'tax_amount' => '9',
        'total_amount' => '100',
        'tax_rate' => BigDecimal('0.1'),
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'price' => '100',
            'quantity' => '1',
            'quantity_unit_code' => 'each',
            'tax_rate' => BigDecimal('0.1'),
            'line_total' => '100'
          }
        }
      }
    )

    expect(result.amount_related_changed?).to be(false)
  end
end
