require 'rails_helper'

RSpec.describe Receipts::Editing::InputBuilder do
  let(:receipt) { create(:receipt) }

  it '送信されたitem更新を既存値へ重ね、未送信itemも保存後集合へ残す' do
    untouched = receipt.receipt_items.create!(
      confirmed_name: '未送信商品', price: 50, quantity: 1, quantity_unit_code: 'each', line_total: 50
    )
    edited = receipt.receipt_items.create!(
      confirmed_name: '編集商品', price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => { 'id' => edited.id.to_s, 'quantity' => '2' }
        }
      }
    )

    aggregate_failures do
      expect(result.receipt_items.map { |item| item['id'] }).to eq([ edited.id.to_s, untouched.id ])
      expect(result.receipt_items.first).to include(
        'price' => 100,
        'quantity' => '2',
        'line_total' => 100,
        'quantity_unit_code' => 'each',
        'amount_price_present' => false,
        'amount_quantity_present' => true,
        'amount_line_total_present' => false,
        'amount_countable_source_changed' => true,
        'amount_line_total_changed' => false
      )
      expect(result.receipt_items.second).to include(
        'confirmed_name' => '未送信商品',
        'line_total' => 50,
        'amount_price_present' => false,
        'amount_quantity_present' => false,
        'amount_line_total_present' => false,
        'amount_countable_source_changed' => false,
        'amount_line_total_changed' => false
      )
    end
  end

  it '送信されたcountable itemのsourceとline_totalが既存値から変わったかを区別する' do
    item = receipt.receipt_items.create!(
      confirmed_name: '税込補正商品',
      price: 130,
      quantity: 1,
      quantity_unit_code: 'each',
      original_line_total: 130,
      line_total: 140
    )

    unchanged = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'price' => '130',
            'quantity' => '1',
            'quantity_unit_code' => 'each',
            'line_total' => '140'
          }
        }
      }
    ).receipt_items.first
    stale_line_total = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'line_total' => '150'
          }
        }
      }
    ).receipt_items.first

    aggregate_failures do
      expect(unchanged).to include(
        'amount_countable_source_changed' => false,
        'amount_line_total_changed' => false,
        'amount_persisted_item' => true,
        'amount_persisted_original_line_total' => 130,
        'amount_persisted_discount_amount' => nil,
        'amount_persisted_discount_rate' => nil,
        'amount_persisted_line_total' => 140
      )
      expect(stale_line_total).to include(
        'amount_countable_source_changed' => false,
        'amount_line_total_changed' => true,
        'amount_persisted_line_total' => 140
      )
    end
  end

  it '削除予定の既存行を除外し、新規行を保存後集合へ追加する' do
    deleted = receipt.receipt_payments.create!(method: '現金', amount: 100)

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_payments_attributes' => {
          '0' => { 'id' => deleted.id.to_s, '_destroy' => '1' },
          '1' => { 'method' => '電子マネー', 'amount' => '100', '_destroy' => '0' }
        }
      }
    )

    expect(result.receipt_payments).to eq([ { 'method' => '電子マネー', 'amount' => '100' } ])
  end

  it '未送信のadjustmentとpaymentを保存後集合へ残す' do
    adjustment = receipt.receipt_adjustments.create!(
      kind: 'bag_fee', label: '袋代', amount: 3, sign: 'surcharge', source: 'manual', needs_review: false
    )
    payment = receipt.receipt_payments.create!(method: '現金', amount: 103)

    result = described_class.call(receipt: receipt, permitted: {})

    aggregate_failures do
      expect(result.receipt_adjustments).to contain_exactly(
        include('id' => adjustment.id, 'kind' => 'bag_fee', 'amount' => 3)
      )
      expect(result.receipt_payments).to contain_exactly(
        include('id' => payment.id, 'method' => '現金', 'amount' => 103)
      )
    end
  end

  it '送信対象の既存adjustmentでも非数値のsource provenanceを保持する' do
    adjustment = receipt.receipt_adjustments.create!(
      kind: 'receipt_discount',
      label: '還元額',
      amount: 22,
      sign: 'discount',
      source: 'ai',
      source_text: 'キャッシュレス還元額 -22',
      needs_review: false
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_adjustments_attributes' => {
          '0' => {
            'id' => adjustment.id.to_s,
            'kind' => adjustment.kind,
            'label' => adjustment.label,
            'amount' => adjustment.amount.to_s,
            'sign' => adjustment.sign
          }
        }
      }
    )

    expect(result.receipt_adjustments.first).to include(
      'source' => 'ai',
      'source_text' => 'キャッシュレス還元額 -22'
    )
  end

  it '同一の既存IDが複数送信された場合は保存後集合を構築しない' do
    item = receipt.receipt_items.create!(
      confirmed_name: '商品', price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100
    )

    expect do
      described_class.call(
        receipt: receipt,
        permitted: {
          'receipt_items_attributes' => {
            '0' => { 'id' => item.id.to_s, 'price' => '100' },
            '1' => { 'id' => item.id.to_s, '_destroy' => '1' }
          }
        }
      )
    end.to raise_error(Receipts::Editing::ConflictError) do |error|
      aggregate_failures do
        expect(error.attributes_key).to eq('receipt_items_attributes')
        expect(error.duplicate_ids).to eq([ item.id.to_s ])
      end
    end
  end

  it 'IDのない同内容の新規行は別々の入力として保持する' do
    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_adjustments_attributes' => {
          '0' => { 'kind' => 'bag_fee', 'amount' => '3' },
          '1' => { 'kind' => 'bag_fee', 'amount' => '3' }
        }
      }
    )

    expect(result.receipt_adjustments).to eq([
      { 'kind' => 'bag_fee', 'amount' => '3' },
      { 'kind' => 'bag_fee', 'amount' => '3' }
    ])
  end
end
