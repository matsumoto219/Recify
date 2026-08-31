require 'rails_helper'

RSpec.describe Amounts::ItemTotalAggregator do
  let(:receipt) { Receipt.new(id: 101) }
  let!(:item) do
    receipt.receipt_items.build(
      id: 202,
      confirmed_name: '検証品',
      pricing_source_kind: 'explicit_line_total',
      price: nil,
      quantity: 1,
      quantity_unit_code: 'piece',
      original_line_total: 50,
      discount_amount: 14,
      discount_rate: BigDecimal('0.27'),
      line_total: 36
    )
  end

  def editing_items(submitted)
    attributes = { 'receipt_items_attributes' => { '0' => { 'id' => item.id.to_s }.merge(submitted) } }
    normalized = Receipts::EditForm.call(receipt:, attributes:)
    Receipts::Editing.build_input(receipt:, permitted: normalized).receipt_items
  end

  it '通常formのsource不変保存で保存済み割引前後金額を保つ' do
    items = editing_items('pricing_source_kind' => 'explicit_line_total', 'original_line_total' => '50', 'discount_rate' => '27')
    expect(items.sole).to include('amount_countable_source_changed' => false, 'line_total' => 50)

    [ :floor, :round, :ceil ].each do |rounding|
      result = described_class.new(items:, context: :edit_save, discount_rounding_mode: rounding).call
      expect(result[:items].sole).to include(original_line_total: 50, discount_amount: 14, line_total: 36)
    end
  end

  it '部分PATCHで計算sourceを送らない場合も保存済み金額を保持する' do
    result = described_class.new(items: editing_items('confirmed_name' => '検証品更新'), context: :edit_save, discount_rounding_mode: :floor).call

    expect(result[:items].sole).to include(original_line_total: 50, discount_amount: 14, line_total: 36)
  end

  it '率または割引前金額を変更した場合は現在の丸め規約で再計算する' do
    [
      [ { 'discount_rate' => '28' }, 50, 14, 36 ],
      [ { 'original_line_total' => '60' }, 60, 16, 44 ]
    ].each do |submitted, original, discount, total|
      result = described_class.new(items: editing_items(submitted), context: :edit_save, discount_rounding_mode: :floor).call
      expect(result[:items].sole).to include(original_line_total: original, discount_amount: discount, line_total: total)
    end
  end

  it 'absolute割引sourceも変更なしなら保持し変更時だけ再計算する' do
    item.assign_attributes(discount_rate: nil, discount_amount: 17, line_total: 33)
    result = described_class.new(items: editing_items('original_line_total' => '50'), context: :edit_save).call
    expect(result[:items].sole).to include(discount_rate: nil, discount_amount: 17, line_total: 33)

    result = described_class.new(items: editing_items('discount_amount' => '18'), context: :edit_save).call
    expect(result[:items].sole).to include(discount_amount: 18, line_total: 32)
  end

  it '保存済み割引前後金額の算術不整合や欠損を保持扱いにしない' do
    [ { line_total: 35 }, { discount_amount: nil } ].each do |attributes|
      item.assign_attributes(discount_amount: 14, line_total: 36, **attributes)
      result = described_class.new(items: editing_items({}), context: :edit_save, discount_rounding_mode: :floor).call
      expect(result[:items].sole).to include(discount_amount: 13, line_total: 37)
    end
  end

  it 'countへのmode変更を既存explicit金額で上書きしない' do
    items = editing_items('pricing_source_kind' => 'count_unit_price', 'price' => '30', 'quantity' => '2', 'quantity_unit_code' => 'piece')
    result = described_class.new(items:, context: :edit_save, discount_rounding_mode: :floor).call

    expect(result[:items].sole).to include(pricing_source_kind: 'count_unit_price', original_line_total: 60, discount_amount: 16, line_total: 44)
  end

  it '新規入力やanalysisでは保存済みsource保持へ入らず既存丸めを使う' do
    [
      [ editing_items({}).sole.except('amount_persisted_item'), :edit_save ],
      [ editing_items({}).sole, :analysis ]
    ].each do |attributes, context|
      attributes = attributes.except('discount_amount') if context == :analysis
      result = described_class.new(items: [ attributes ], context:, discount_rounding_mode: :floor).call
      expect(result[:items].sole).to include(discount_amount: 13, line_total: 37)
    end
  end

  it '明示0円と全額absolute割引もsourceとderivedを一致させて保持する' do
    [ [ 0, 0, 0 ], [ 50, 50, 0 ] ].each do |original, discount, total|
      item.assign_attributes(original_line_total: original, discount_amount: discount, line_total: total, discount_rate: nil)
      result = described_class.new(items: editing_items('original_line_total' => original.to_s), context: :edit_save).call
      expect(result[:items].sole).to include(original_line_total: original, discount_amount: discount, line_total: total, discount_rate: nil)
    end
  end
end
