require 'rails_helper'

RSpec.describe 'Receipts::Editing managed amount persistence' do
  let(:settings) do
    {
      'schema_version' => 1,
      'tax_rounding_mode' => { 'value' => 'floor', 'origin' => 'manual' },
      'discount_rounding_mode' => { 'value' => 'round', 'origin' => 'manual' },
      'tax_rounding_scope' => { 'value' => 'per_tax_rate_group', 'origin' => 'application_default' },
      'purchase_adjustment_tax_inclusion' => { 'value' => 'gross', 'origin' => 'manual' }
    }
  end

  def source_item(price: 19, basis: 'net', **attributes)
    {
      pricing_source_kind: 'count_unit_price',
      price: price,
      quantity: 1,
      quantity_unit_code: 'each',
      tax_rate: BigDecimal('0.1'),
      input_tax_inclusion: basis,
      tax_inclusion_origin: 'manual'
    }.merge(attributes)
  end

  def calculate(items, context: :manual)
    ReceiptAmountService.call(
      receipt: { calculation_settings: settings },
      receipt_items: items,
      receipt_tax_details: [],
      context: context
    )
  end

  def apply(receipt, attributes, result, context: :manual)
    Receipts::Editing.apply_amount_result!(
      receipt: receipt,
      attributes: attributes,
      amount_result: result,
      context: context,
      change_set: nil,
      tax_details_recalculated: true
    )
  end

  def guard(items, result, adjustments: [])
    Receipts::Editing.check_consistency(
      receipt_items: items,
      receipt_adjustments: adjustments,
      receipt_payments: [],
      amount_result: result,
      calculation_settings: settings
    )
  end

  it 'managed manualでは入力sourceと税込参考額を分離し、group丸め差を配賦しない' do
    receipt = build(:receipt, calculation_settings: settings)
    items = [ source_item, source_item ]
    attributes = {
      'calculation_settings' => settings,
      'receipt_items_attributes' => items.each_with_index.to_h { |item, index| [ index.to_s, item.stringify_keys ] }
    }
    result = calculate(items)

    apply(receipt, attributes, result)
    saved = attributes.fetch('receipt_items_attributes').values

    aggregate_failures do
      expect(attributes['total_amount']).to eq(41)
      expect(saved.pluck('price')).to eq([ 19, 19 ])
      expect(saved.pluck('line_total')).to eq([ 19, 19 ])
      expect(saved.pluck('gross_line_total')).to eq([ 20, 20 ])
      expect(guard(saved, result)).to be_consistent
    end
  end

  it 'mixed入力をsourceとprojectionとgroupの各契約で検証する' do
    items = [ source_item, source_item(price: 22, basis: 'gross') ]
    result = calculate(items)
    attributes = {
      'calculation_settings' => settings,
      'receipt_items_attributes' => items.each_with_index.to_h { |item, index| [ index.to_s, item.stringify_keys ] }
    }
    apply(build(:receipt), attributes, result)

    expect(attributes['total_amount']).to eq(42)
    expect(guard(attributes['receipt_items_attributes'].values, result)).to be_consistent
  end

  it '明細なしのReceipt入力額を保ち、架空の明細や税込参考額を追加しない' do
    receipt = create(:receipt, total_amount: 1400)
    attributes = { 'calculation_settings' => settings, 'total_amount' => 3300, 'subtotal_amount' => 3000, 'tax_amount' => 300 }
    result = ReceiptAmountService.call(
      receipt: attributes.symbolize_keys,
      receipt_items: [],
      receipt_tax_details: [],
      context: :edit_save
    )

    apply(receipt, attributes, result, context: :edit_save)

    expect(attributes).to include('total_amount' => 3300, 'subtotal_amount' => 3000, 'tax_amount' => 300)
    expect(attributes['receipt_items_attributes']).to be_blank
    expect(guard([], result)).to be_consistent
  end

  it '金額未入力の既存明細はReceipt入力額の保存で0円sourceへ変更しない' do
    receipt = create(:receipt, total_amount: 1400)
    item = receipt.receipt_items.create!(confirmed_name: '金額未入力', price: nil, line_total: nil)
    attributes = { 'calculation_settings' => settings, 'total_amount' => 3300, 'subtotal_amount' => 3000, 'tax_amount' => 300 }
    input = Receipts::Editing.build_input(receipt:, permitted: attributes)
    result = ReceiptAmountService.call(
      receipt: attributes.symbolize_keys,
      receipt_items: input.receipt_items,
      receipt_tax_details: [],
      context: :edit_save
    )

    apply(receipt, attributes, result, context: :edit_save)

    expect(attributes).to include('total_amount' => 3300, 'subtotal_amount' => 3000, 'tax_amount' => 300)
    expect(attributes['receipt_items_attributes']).to be_blank
    expect(guard([ item ], result)).to be_consistent
  end

  it '新規の金額未入力明細へ架空の税込参考額やsourceを追加しない' do
    item = { confirmed_name: '金額未入力', price: nil, quantity: 1, quantity_unit_code: 'each', line_total: nil }
    attributes = {
      'calculation_settings' => settings,
      'total_amount' => 0,
      'subtotal_amount' => 0,
      'tax_amount' => 0,
      'receipt_items_attributes' => { '0' => item.stringify_keys }
    }
    result = ReceiptAmountService.call(
      receipt: attributes.symbolize_keys,
      receipt_items: [ item ],
      receipt_tax_details: [],
      context: :manual
    )

    apply(build(:receipt), attributes, result)

    expect(attributes['total_amount']).to eq(0)
    expect(attributes['receipt_items_attributes']['0']).not_to have_key('gross_line_total')
    expect(attributes['receipt_items_attributes']['0']['price']).to be_nil
    expect(guard(attributes['receipt_items_attributes'].values, result)).to be_consistent
  end

  it 'authority未分類の計量入力は単価から金額を補完せず既存のReceipt入力を維持する' do
    item = {
      confirmed_name: '計量入力',
      price: 14_400,
      quantity: BigDecimal('0.300'),
      quantity_unit_code: 'kilogram',
      tax_rate: BigDecimal('0.1'),
      line_total: nil
    }
    attributes = {
      'calculation_settings' => settings,
      'total_amount' => 0,
      'subtotal_amount' => 0,
      'tax_amount' => 0,
      'receipt_items_attributes' => { '0' => item.stringify_keys }
    }
    result = ReceiptAmountService.call(
      receipt: attributes.symbolize_keys,
      receipt_items: [ item ],
      receipt_tax_details: [],
      context: :manual
    )

    apply(build(:receipt), attributes, result)

    expect(attributes['total_amount']).to eq(0)
    expect(attributes['receipt_items_attributes']['0']).to include('price' => 14_400, 'line_total' => 0)
    expect(attributes['receipt_items_attributes']['0']).not_to have_key('gross_line_total')
    expect(guard(attributes['receipt_items_attributes'].values, result)).to be_consistent
  end

  it 'typed明細をReceipt入力の互換経路へ逃がしてsource検証を省略しない' do
    result = calculate([ source_item ])
    result[:computed][:amount_engine_basis] = 'receipt_input_preserved'
    attributes = {
      'calculation_settings' => settings,
      'receipt_items_attributes' => { '0' => source_item.stringify_keys }
    }

    expect do
      apply(build(:receipt), attributes, result)
    end.to raise_error(Receipts::Editing::InvalidItemSourceError)
    expect(guard(attributes['receipt_items_attributes'].values, result)).not_to be_consistent
  end

  it 'partial PATCHの編集行と未送信行をIDで対応させ、他の属性を上書きしない' do
    receipt = create(:receipt, calculation_settings: settings)
    retained = receipt.receipt_items.create!(source_item.merge(confirmed_name: '未送信', line_total: 19, original_line_total: 19))
    edited = receipt.receipt_items.create!(source_item(price: 22, basis: 'gross').merge(confirmed_name: '編集', line_total: 22, original_line_total: 22))
    attributes = {
      'receipt_items_attributes' => { '9' => { 'id' => edited.id.to_s, 'quantity' => '2' } }
    }
    input = Receipts::Editing.build_input(receipt: receipt, permitted: attributes)
    result = calculate(input.receipt_items, context: :edit_save)

    apply(receipt, attributes, result, context: :edit_save)
    saved = attributes.fetch('receipt_items_attributes').values.index_by { |item| item['id'].to_s }

    aggregate_failures do
      expect(saved.keys).to contain_exactly(edited.id.to_s, retained.id.to_s)
      expect(saved.fetch(edited.id.to_s)).to include('line_total' => 44, 'gross_line_total' => 44)
      expect(saved.fetch(retained.id.to_s)).to include('line_total' => 19, 'gross_line_total' => 20)
      expect(saved.fetch(retained.id.to_s)).not_to have_key('confirmed_name')
      complete = Receipts::Editing.build_input(receipt: receipt, permitted: attributes).receipt_items
      expect(guard(complete, result)).to be_consistent
    end
  end

  %i[price quantity input_tax_inclusion line_total gross_line_total].each do |field|
    it "保存予定の#{field}だけを改変した場合は保存不能にする" do
      result = calculate([ source_item ])
      saved = result.dig(:computed, :source_items).sole.merge(
        gross_line_total: result.dig(:computed, :items).sole[:line_total]
      )
      saved[field] = field == :input_tax_inclusion ? 'gross' : 999

      expect(guard([ saved ], result)).not_to be_consistent
    end
  end

  it '税込参考額の合計が正しくてもtax groupの改変を拒否する' do
    result = calculate([ source_item ])
    saved = result.dig(:computed, :source_items).sole.merge(gross_line_total: 20)
    result[:computed][:tax_rate_groups].sole[:net] += 1

    expect(guard([ saved ], result)).not_to be_consistent
  end

  %i[source_items items].each do |field|
    it "managed結果の#{field}が欠損した場合は候補値へfallbackせず拒否する" do
      result = calculate([ source_item ])
      result[:computed].delete(field)
      attributes = {
        'calculation_settings' => settings,
        'receipt_items_attributes' => { '0' => source_item.stringify_keys }
      }

      expect do
        apply(build(:receipt), attributes, result)
      end.to raise_error(Receipts::Editing::InvalidItemSourceError)
    end
  end

  it 'candidate本体とstatusが不一致なmanaged結果から税込参考額を作らない' do
    result = calculate([ source_item ])
    result[:selected_candidate_status] = 'rejected'
    attributes = {
      'calculation_settings' => settings,
      'receipt_items_attributes' => { '0' => source_item.stringify_keys }
    }

    expect do
      apply(build(:receipt), attributes, result)
    end.to raise_error(Receipts::Editing::InvalidItemSourceError)
  end

  it '支払調整だけが過大でも整合する購入sourceを維持し、review判定で保存できる' do
    items = [ source_item(price: 100, basis: 'gross') ]
    adjustments = [ { kind: 'point_usage', amount: 200, sign: 'discount' } ]
    result = ReceiptAmountService.call(
      receipt: { calculation_settings: settings },
      receipt_items: items,
      receipt_tax_details: [],
      receipt_adjustments: adjustments,
      context: :manual
    )
    attributes = {
      'calculation_settings' => settings,
      'receipt_items_attributes' => { '0' => items.sole.stringify_keys }
    }

    apply(build(:receipt), attributes, result)

    expect(result[:selected_candidate_status]).to eq('rejected')
    expect(attributes['total_amount']).to eq(100)
    expect(attributes['receipt_items_attributes']['0']).to include('price' => 100, 'line_total' => 100, 'gross_line_total' => 100)
    checked = guard(attributes['receipt_items_attributes'].values, result, adjustments: adjustments)
    expect(checked).to be_consistent
    expect(checked.review_reasons).to include('invalid_amount_relation')
  end

  it '新規explicit netでは割引前後のsourceと税込参考額をsave/reload後も保持する' do
    receipt = create(:receipt, calculation_settings: settings)
    item = {
      confirmed_name: '明細',
      pricing_source_kind: 'explicit_line_total',
      quantity: 3,
      quantity_unit_code: 'each',
      input_tax_inclusion: 'net',
      tax_inclusion_origin: 'manual',
      tax_rate: BigDecimal('0.1'),
      original_line_total: 500,
      line_total: 500,
      discount_amount: 20
    }
    attributes = { 'receipt_items_attributes' => { '0' => item.stringify_keys } }
    result = calculate([ item ])
    apply(receipt, attributes, result)
    receipt.update!(attributes)
    saved = receipt.reload.receipt_items.sole

    expect(saved).to have_attributes(
      price: nil,
      quantity: 3,
      original_line_total: 500,
      line_total: 480,
      discount_amount: 20,
      discount_rate: nil,
      gross_line_total: 528,
      input_tax_inclusion: 'net',
      tax_inclusion_origin: 'manual'
    )
    retry_input = Receipts::Editing.build_input(receipt: receipt, permitted: {}).receipt_items
    retried = calculate(retry_input, context: :edit_save)
    retry_attributes = {}
    apply(receipt, retry_attributes, retried, context: :edit_save)
    receipt.update!(retry_attributes)

    expect(receipt.reload.receipt_items.sole).to have_attributes(line_total: 480, gross_line_total: 528, discount_amount: 20)
    expect(receipt.total_amount).to eq(528)
  end

  it '未送信行の欠落とsource/projectionのID入替を拒否する' do
    receipt = create(:receipt, calculation_settings: settings)
    2.times do |index|
      receipt.receipt_items.create!(source_item.merge(confirmed_name: "明細#{index}", line_total: 19, original_line_total: 19))
    end
    input = Receipts::Editing.build_input(receipt: receipt, permitted: {}).receipt_items
    result = calculate(input, context: :edit_save)
    swapped = result.deep_dup
    swapped[:computed][:items].reverse!
    missing = result.deep_dup
    missing[:computed][:items].pop
    missing[:computed][:source_items].pop

    [ swapped, missing ].each do |invalid_result|
      expect do
        apply(receipt, {}, invalid_result, context: :edit_save)
      end.to raise_error(Receipts::Editing::InvalidItemSourceError)
    end
  end

  it '重複IDとReceipt外の送信IDを保持行へ紛れ込ませない' do
    receipt = create(:receipt, calculation_settings: settings)
    item = receipt.receipt_items.create!(source_item.merge(confirmed_name: '明細', line_total: 19, original_line_total: 19))
    result = calculate(Receipts::Editing.build_input(receipt: receipt, permitted: {}).receipt_items, context: :edit_save)
    [
      { '0' => { 'id' => item.id.to_s }, '1' => { 'id' => item.id.to_s } },
      { '0' => { 'id' => (item.id + 1).to_s } }
    ].each do |item_attributes|
      expect do
        apply(receipt, { 'receipt_items_attributes' => item_attributes }, result, context: :edit_save)
      end.to raise_error(Receipts::Editing::InvalidItemSourceError)
    end
  end

  it '削除した行を復活させず、新規行と保存済み行のprojectionを区別する' do
    receipt = create(:receipt, calculation_settings: settings)
    removed = receipt.receipt_items.create!(source_item.merge(confirmed_name: '削除', line_total: 19, original_line_total: 19))
    kept = receipt.receipt_items.create!(source_item(price: 22, basis: 'gross').merge(confirmed_name: '保持', line_total: 22, original_line_total: 22))
    attributes = {
      'receipt_items_attributes' => {
        '4' => { 'id' => removed.id.to_s, '_destroy' => '1' },
        '8' => source_item(price: 30).merge(confirmed_name: '新規').stringify_keys
      }
    }
    input = Receipts::Editing.build_input(receipt: receipt, permitted: attributes)
    result = calculate(input.receipt_items, context: :edit_save)

    apply(receipt, attributes, result, context: :edit_save)
    active = attributes['receipt_items_attributes'].values.reject { |item| item['_destroy'] == '1' }
    expect(active.find { |item| item['id'].nil? }).to include('line_total' => 30, 'gross_line_total' => 33)
    expect(active.find { |item| item['id'].to_s == kept.id.to_s }).to include('line_total' => 22, 'gross_line_total' => 22)
    expect(attributes['receipt_items_attributes']['4']).to eq('id' => removed.id.to_s, '_destroy' => '1')
  end

  it 'sourceと同じ金額を持つ別itemのidentityや重複をguardが拒否する' do
    result = calculate([ source_item(id: 123), source_item(id: 124) ], context: :edit_save)
    saved = result.dig(:computed, :source_items).map { |source| source.merge(gross_line_total: 20) }

    expect(guard(saved.reverse, result)).to be_consistent
    saved.last[:id] = saved.first[:id]
    expect(guard(saved, result)).not_to be_consistent
  end

  it 'sourceと税込参考額の検証はDB・再計算を行わない' do
    result = calculate([ source_item ])
    saved = result.dig(:computed, :source_items).sole.merge(gross_line_total: 20)
    expect(ReceiptAmountService).not_to receive(:call)
    expect(Receipt).not_to receive(:find)
    expect(ReceiptItem).not_to receive(:find)

    expect(guard([ saved ], result)).to be_consistent
  end

  it 'referenceのexact sourceをper-one価格や税込sourceへ変更しない' do
    item = {
      pricing_source_kind: 'reference_quantity_price',
      reference_price_amount: BigDecimal('100.5'),
      reference_quantity: BigDecimal('100'),
      reference_quantity_unit_code: 'gram',
      reference_price_tax_inclusion: 'net',
      tax_inclusion_origin: 'manual',
      quantity: BigDecimal('250'),
      quantity_unit_code: 'gram',
      tax_rate: BigDecimal('0.1')
    }
    attributes = { 'calculation_settings' => settings, 'receipt_items_attributes' => { '0' => item.stringify_keys } }
    result = calculate([ item ])

    apply(build(:receipt), attributes, result)
    saved = attributes['receipt_items_attributes']['0']

    expect(saved).to include(
      'price' => nil,
      'reference_price_amount' => BigDecimal('100.5'),
      'reference_quantity' => BigDecimal('100'),
      'quantity' => BigDecimal('250'),
      'reference_price_tax_inclusion' => 'net',
      'line_total' => 251,
      'gross_line_total' => 276
    )
    expect(guard([ saved ], result)).to be_consistent
  end

  it 'referenceの非authority priceを維持し、exact reference sourceと税込参考額を検証する' do
    receipt = create(:receipt, calculation_settings: settings)
    item = receipt.receipt_items.create!(
      confirmed_name: '計量明細',
      pricing_source_kind: 'reference_quantity_price',
      price: 999,
      reference_price_amount: BigDecimal('100'),
      reference_quantity: BigDecimal('100'),
      reference_quantity_unit_code: 'gram',
      reference_price_tax_inclusion: 'net',
      quantity: BigDecimal('250'),
      quantity_unit_code: 'gram',
      tax_rate: BigDecimal('0.1'),
      original_line_total: 250,
      line_total: 250
    )
    attributes = { 'receipt_items_attributes' => { '0' => { 'id' => item.id.to_s, 'quantity' => '300', 'price' => nil } } }
    result = calculate(Receipts::Editing.build_input(receipt:, permitted: attributes).receipt_items, context: :edit_save)

    apply(receipt, attributes, result, context: :edit_save)
    complete = Receipts::Editing.build_input(receipt:, permitted: attributes).receipt_items

    expect(attributes['receipt_items_attributes']['0']).to include('price' => 999, 'line_total' => 300, 'gross_line_total' => 330)
    expect(guard(complete, result)).to be_consistent
    complete.sole[:reference_price_amount] = BigDecimal('101')
    expect(guard(complete, result)).not_to be_consistent
  end

  [ '1e999999999', '9' * 129, "19\u0000", '1_9', Float::NAN ].each do |value|
    it "不正・過大なsource token #{value.inspect[0, 24]} を整合済みとして扱わない" do
      result = calculate([ source_item ])
      saved = result.dig(:computed, :source_items).sole.merge(gross_line_total: 20, price: value)

      expect(guard([ saved ], result)).not_to be_consistent
    end
  end
end
