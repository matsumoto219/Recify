require 'rails_helper'

RSpec.describe Receipts::Editing::ChangeSet do
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

    aggregate_failures do
      expect(result.purchase_amounts_changed?).to be(false)
      expect(result.amount_inputs_submitted?).to be(false)
    end
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

  it 'countable itemのstale hidden line_totalだけをpurchase amount変更にしない' do
    item = receipt.receipt_items.create!(
      confirmed_name: '商品', price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => { 'id' => item.id.to_s, 'line_total' => '150' }
        }
      }
    )

    aggregate_failures do
      expect(result.purchase_amounts_changed?).to be(false)
      expect(result.amount_inputs_submitted?).to be(true)
    end
  end

  it 'itemの非金額変更と同時に送られた同値金額を再確認扱いにしない' do
    item = receipt.receipt_items.create!(
      confirmed_name: '商品', category: nil, price: 100, quantity: 1,
      quantity_unit_code: 'each', tax_rate: BigDecimal('0.1'), line_total: 100
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'category' => 'food',
            'price' => '100',
            'quantity' => '1',
            'quantity_unit_code' => 'each',
            'tax_rate' => BigDecimal('0.1'),
            'line_total' => '100'
          }
        }
      }
    )

    aggregate_failures do
      expect(result.amount_related_changed?).to be(false)
      expect(result.amount_inputs_submitted?).to be(false)
    end
  end

  it '同値のreceipt金額だけの送信を再確認扱いにしない' do
    result = described_class.call(
      receipt: receipt,
      permitted: { 'total_amount' => receipt.total_amount.to_s }
    )

    aggregate_failures do
      expect(result.amount_related_changed?).to be(false)
      expect(result.amount_inputs_submitted?).to be(false)
    end
  end

  it '説明不能な保存済みcountable totalは同値priceとquantityの送信でも変更として扱う' do
    item = receipt.receipt_items.create!(
      confirmed_name: '商品', price: 100, quantity: 2,
      quantity_unit_code: 'each', line_total: 100
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'price' => '100',
            'quantity' => '2',
            'quantity_unit_code' => 'each',
            'line_total' => '200'
          }
        }
      }
    )

    aggregate_failures do
      expect(result.purchase_amounts_changed?).to be(true)
      expect(result.amount_inputs_submitted?).to be(true)
    end
  end

  it 'measurement itemの明示line_total変更をpurchase amount変更にする' do
    item = receipt.receipt_items.create!(
      confirmed_name: '量り売り', price: 1_000, quantity: 0.5, quantity_unit_code: 'kilogram', line_total: 500
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => { 'id' => item.id.to_s, 'line_total' => '550' }
        }
      }
    )

    expect(result.purchase_amounts_changed?).to be(true)
  end

  it '単価のないcountable itemの明示line_total変更をpurchase amount変更にする' do
    item = receipt.receipt_items.create!(
      confirmed_name: '総額のみ', price: nil, quantity: 1, quantity_unit_code: 'each', line_total: 500
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => { 'id' => item.id.to_s, 'line_total' => '550' }
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

    aggregate_failures do
      expect(result.amount_related_changed?).to be(false)
      expect(result.amount_inputs_submitted?).to be(true)
    end
  end

  it 'labelだけで購入調整から支払調整へ変わる変更を両側の変更として検出する' do
    adjustment = receipt.receipt_adjustments.create!(
      kind: 'receipt_discount',
      label: 'レシート値引き',
      amount: 10,
      sign: 'discount',
      tax_rate: BigDecimal('0.10'),
      source: 'manual'
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_adjustments_attributes' => {
          '0' => {
            'id' => adjustment.id.to_s,
            'kind' => adjustment.kind,
            'label' => 'キャッシュレス還元',
            'amount' => adjustment.amount.to_s,
            'sign' => adjustment.sign,
            'tax_rate' => adjustment.tax_rate.to_s
          }
        }
      }
    )

    aggregate_failures do
      expect(result.purchase_adjustments_changed).to be(true)
      expect(result.payment_adjustments_changed).to be(true)
      expect(result.amount_related_changed?).to be(true)
    end
  end
end
