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

  def create_reference_item(**attributes)
    receipt.receipt_items.create!(
      {
        confirmed_name: '基準価格商品',
        price: nil,
        quantity: BigDecimal('8.12'),
        quantity_unit_code: 'liter',
        original_line_total: 1_137,
        line_total: 1_137,
        pricing_source_kind: 'reference_quantity_price',
        reference_price_amount: BigDecimal('140'),
        reference_quantity: BigDecimal('1'),
        reference_quantity_unit_code: 'liter',
        reference_price_tax_inclusion: 'gross'
      }.merge(attributes)
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

  it '1万件相当のitem照合でもassociationを1回だけ読み1回だけ走査する' do
    lightweight_item_class = Struct.new(:id) do
      def assign_attributes(attributes)
        raise "unexpected attributes: #{attributes.inspect}" if attributes.present?
      end
    end
    records = Array.new(10_000) { |index| lightweight_item_class.new(index + 1) }
    association_reads = 0
    association_iterations = 0
    collection = Object.new
    collection.extend(Enumerable)
    collection.define_singleton_method(:each) do |&block|
      association_iterations += 1
      raise 'receipt_items association was scanned more than once' if association_iterations > 1

      records.each(&block)
    end
    large_receipt = instance_double(Receipt)
    allow(large_receipt).to receive(:receipt_items) do
      association_reads += 1
      raise 'receipt_items association was read more than once' if association_reads > 1

      collection
    end
    permitted = {
      'receipt_items_attributes' => records.to_h do |record|
        [ record.id.to_s, { 'id' => record.id.to_s } ]
      end
    }

    result = described_class.call(receipt: large_receipt, permitted: permitted)

    aggregate_failures do
      expect(result.amount_related_changed?).to be(false)
      expect(association_reads).to eq(1)
      expect(association_iterations).to eq(1)
    end
  end

  it 'Q2の全source fieldの変更をpurchase amount変更として検出する' do
    changed_values = {
      'pricing_source_kind' => 'explicit_line_total',
      'reference_price_amount' => BigDecimal('141'),
      'reference_quantity' => BigDecimal('2'),
      'reference_quantity_unit_code' => 'milliliter',
      'quantity_unit_raw' => 'unknown-purchased-unit',
      'reference_quantity_unit_raw' => 'unknown-reference-unit',
      'reference_price_tax_inclusion' => 'net'
    }

    results = changed_values.map do |field, value|
      item = create_reference_item

      described_class.call(
        receipt: receipt,
        permitted: {
          'receipt_items_attributes' => {
            '0' => { 'id' => item.id.to_s, field => value }
          }
        }
      )
    end

    aggregate_failures do
      expect(results).to all(have_attributes(item_amounts_changed: true))
      expect(results).to all(be_amount_inputs_submitted)
    end
  end

  it '0円のreference authorityを金額sourceとして検出する' do
    item = create_reference_item(
      reference_price_amount: BigDecimal('0'),
      original_line_total: nil,
      line_total: nil
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => { 'id' => item.id.to_s, 'quantity' => BigDecimal('9.12') }
        }
      }
    )

    aggregate_failures do
      expect(result.item_amounts_changed).to be(true)
      expect(result.amount_inputs_submitted?).to be(true)
    end
  end

  it 'Q2 source fieldの同値再送をpurchase amount変更にしない' do
    item = create_reference_item

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'pricing_source_kind' => item.pricing_source_kind,
            'reference_price_amount' => item.reference_price_amount,
            'reference_quantity' => item.reference_quantity,
            'reference_quantity_unit_code' => item.reference_quantity_unit_code,
            'quantity_unit_raw' => item.quantity_unit_raw,
            'reference_quantity_unit_raw' => item.reference_quantity_unit_raw,
            'reference_price_tax_inclusion' => item.reference_price_tax_inclusion
          }
        }
      }
    )

    aggregate_failures do
      expect(result.item_amounts_changed).to be(false)
      expect(result.amount_inputs_submitted?).to be(true)
    end
  end

  it '割引済みexplicit authorityの同値再送をpurchase amount変更にしない' do
    item = receipt.receipt_items.create!(
      confirmed_name: '明示金額商品',
      quantity: BigDecimal('1'),
      quantity_unit_code: 'each',
      pricing_source_kind: 'explicit_line_total',
      original_line_total: 200,
      discount_rate: BigDecimal('0.1'),
      discount_amount: 20,
      line_total: 180
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'pricing_source_kind' => 'explicit_line_total',
            'original_line_total' => '200',
            'line_total' => '200',
            'discount_rate' => BigDecimal('0.1')
          }
        }
      }
    )

    aggregate_failures do
      expect(result.item_amounts_changed).to be(false)
      expect(result.derived_purchase_inputs_changed?).to be(false)
      expect(result.amount_inputs_submitted?).to be(true)
    end
  end

  it '割引済みexplicit authorityの変更を保存済みderived totalと同値でも検出する' do
    item = receipt.receipt_items.create!(
      confirmed_name: '明示金額商品',
      quantity: BigDecimal('1'),
      quantity_unit_code: 'each',
      pricing_source_kind: 'explicit_line_total',
      original_line_total: 200,
      discount_rate: BigDecimal('0.1'),
      discount_amount: 20,
      line_total: 180
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'pricing_source_kind' => 'explicit_line_total',
            'original_line_total' => '180',
            'line_total' => '180',
            'discount_rate' => BigDecimal('0.1')
          }
        }
      }
    )

    aggregate_failures do
      expect(result.item_amounts_changed).to be(true)
      expect(result.derived_purchase_inputs_changed?).to be(true)
    end
  end

  it '0円のexplicit authorityをblankと混同せず同値と変更を区別する' do
    item = receipt.receipt_items.create!(
      confirmed_name: '0円商品',
      quantity: BigDecimal('1'),
      quantity_unit_code: 'each',
      pricing_source_kind: 'explicit_line_total',
      original_line_total: 0,
      line_total: 0
    )

    unchanged = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'pricing_source_kind' => 'explicit_line_total',
            'original_line_total' => '0',
            'line_total' => '0'
          }
        }
      }
    )
    changed = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'pricing_source_kind' => 'explicit_line_total',
            'original_line_total' => '1',
            'line_total' => '1'
          }
        }
      }
    )

    aggregate_failures do
      expect(unchanged.item_amounts_changed).to be(false)
      expect(changed.item_amounts_changed).to be(true)
    end
  end

  it '絶対額割引のexplicit authority同値再送をpurchase amount変更にしない' do
    item = receipt.receipt_items.create!(
      confirmed_name: '絶対額割引商品',
      quantity: BigDecimal('1'),
      quantity_unit_code: 'each',
      pricing_source_kind: 'explicit_line_total',
      original_line_total: 200,
      discount_rate: nil,
      discount_amount: 20,
      line_total: 180
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'pricing_source_kind' => 'explicit_line_total',
            'original_line_total' => '200',
            'line_total' => '200'
          }
        }
      }
    )

    expect(result.derived_purchase_inputs_changed?).to be(false)
  end

  it 'original未記録の保存済みexplicit rowは明示送信値をauthority化する' do
    item = receipt.receipt_items.create!(
      confirmed_name: 'original未記録商品',
      quantity: BigDecimal('1'),
      quantity_unit_code: 'each',
      pricing_source_kind: 'explicit_line_total',
      original_line_total: nil,
      line_total: 200
    )

    unchanged = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'pricing_source_kind' => 'explicit_line_total',
            'original_line_total' => '200',
            'line_total' => '200'
          }
        }
      }
    )
    changed = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'pricing_source_kind' => 'explicit_line_total',
            'original_line_total' => '180',
            'line_total' => '180'
          }
        }
      }
    )

    aggregate_failures do
      expect(unchanged.derived_purchase_inputs_changed?).to be(true)
      expect(changed.derived_purchase_inputs_changed?).to be(true)
    end
  end

  it 'originalが0の保存済みexplicit rowは0円authorityを優先しderived不整合を検出する' do
    item = receipt.receipt_items.create!(
      confirmed_name: 'original 0円商品',
      quantity: BigDecimal('1'),
      quantity_unit_code: 'each',
      pricing_source_kind: 'explicit_line_total',
      original_line_total: 0,
      line_total: 500
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'pricing_source_kind' => 'explicit_line_total',
            'original_line_total' => '0',
            'line_total' => '0'
          }
        }
      }
    )

    expect(result.derived_purchase_inputs_changed?).to be(true)
  end

  it 'original未記録positive-discount explicit rowのnon-amount partial入力をsource変更にしない' do
    item = receipt.receipt_items.create!(
      confirmed_name: 'authority不明商品',
      quantity: BigDecimal('1'),
      quantity_unit_code: 'each',
      pricing_source_kind: 'explicit_line_total',
      original_line_total: nil,
      discount_rate: BigDecimal('0.1'),
      discount_amount: 18,
      line_total: 180
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'confirmed_name' => '名称だけ変更'
          }
        }
      }
    )

    expect(result.derived_purchase_inputs_changed?).to be(false)
  end

  it 'discount sourceのないexplicit rowの説明不能なderived totalを正規化対象として検出する' do
    item = receipt.receipt_items.create!(
      confirmed_name: 'derived不整合商品',
      quantity: BigDecimal('1'),
      quantity_unit_code: 'each',
      pricing_source_kind: 'explicit_line_total',
      original_line_total: 200,
      discount_rate: nil,
      discount_amount: nil,
      line_total: 180
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'pricing_source_kind' => 'explicit_line_total',
            'original_line_total' => '200',
            'line_total' => '200'
          }
        }
      }
    )

    expect(result.derived_purchase_inputs_changed?).to be(true)
  end

  it 'explicitのhidden line totalのみの差し替えをsource変更にしない' do
    item = receipt.receipt_items.create!(
      confirmed_name: '明示金額商品',
      quantity: BigDecimal('1'),
      quantity_unit_code: 'each',
      pricing_source_kind: 'explicit_line_total',
      original_line_total: 200,
      line_total: 200
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'pricing_source_kind' => 'explicit_line_total',
            'line_total' => '999'
          }
        }
      }
    )

    expect(result.derived_purchase_inputs_changed?).to be(false)
  end

  it 'explicitのdiscount rate変更はauthority同値でも検出する' do
    item = receipt.receipt_items.create!(
      confirmed_name: '割引率変更商品',
      quantity: BigDecimal('1'),
      quantity_unit_code: 'each',
      pricing_source_kind: 'explicit_line_total',
      original_line_total: 200,
      discount_rate: BigDecimal('0.1'),
      discount_amount: 20,
      line_total: 180
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'pricing_source_kind' => 'explicit_line_total',
            'original_line_total' => '200',
            'line_total' => '200',
            'discount_rate' => BigDecimal('0.2')
          }
        }
      }
    )

    expect(result.derived_purchase_inputs_changed?).to be(true)
  end

  it '非金額項目だけを変更してQ2 sourceを同値再送しても金額再確認扱いにしない' do
    item = create_reference_item(category: nil)

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'category' => 'drink',
            'pricing_source_kind' => item.pricing_source_kind,
            'reference_price_amount' => item.reference_price_amount,
            'reference_quantity' => item.reference_quantity,
            'reference_quantity_unit_code' => item.reference_quantity_unit_code,
            'quantity_unit_raw' => item.quantity_unit_raw,
            'reference_quantity_unit_raw' => item.reference_quantity_unit_raw,
            'reference_price_tax_inclusion' => item.reference_price_tax_inclusion
          }
        }
      }
    )

    aggregate_failures do
      expect(result.amount_related_changed?).to be(false)
      expect(result.amount_inputs_submitted?).to be(false)
    end
  end

  it 'reference formulaのstale line_totalだけをpurchase amount変更にしない' do
    item = create_reference_item

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => { 'id' => item.id.to_s, 'line_total' => '999' }
        }
      }
    )

    aggregate_failures do
      expect(result.purchase_amounts_changed?).to be(false)
      expect(result.amount_inputs_submitted?).to be(true)
    end
  end

  it '金額sourceを持たないplaceholderのquantity変更をpurchase amount変更にしない' do
    item = receipt.receipt_items.create!(
      confirmed_name: '金額未入力', price: nil, quantity: 1,
      quantity_unit_code: 'each', original_line_total: nil, line_total: nil
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'price' => '',
            'quantity' => '2',
            'quantity_unit_code' => 'each',
            'original_line_total' => '',
            'line_total' => ''
          }
        }
      }
    )

    aggregate_failures do
      expect(result.purchase_amounts_changed?).to be(false)
      expect(result.amount_inputs_submitted?).to be(true)
    end
  end

  it 'originalとdiscountの0だけを持つplaceholderも金額source扱いにしない' do
    item = receipt.receipt_items.create!(
      confirmed_name: '金額未入力', price: nil, quantity: 1,
      quantity_unit_code: 'each', original_line_total: 0, discount_amount: 0, line_total: nil
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_items_attributes' => {
          '0' => {
            'id' => item.id.to_s,
            'quantity' => '2',
            'original_line_total' => '',
            'line_total' => ''
          }
        }
      }
    )

    expect(result.purchase_amounts_changed?).to be(false)
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

  it 'labelのnilとblankの差だけでは購入金額sourceをstaleにしない' do
    adjustment = receipt.receipt_adjustments.create!(
      kind: 'delivery_fee',
      label: nil,
      amount: 10,
      sign: 'surcharge',
      tax_rate: nil,
      source: 'manual'
    )

    result = described_class.call(
      receipt: receipt,
      permitted: {
        'receipt_adjustments_attributes' => {
          '0' => {
            'id' => adjustment.id.to_s,
            'kind' => adjustment.kind,
            'label' => '',
            'amount' => adjustment.amount.to_s,
            'sign' => adjustment.sign,
            'tax_rate' => ''
          }
        }
      }
    )

    aggregate_failures do
      expect(result.purchase_adjustments_changed).to be(false)
      expect(result.payment_adjustments_changed).to be(false)
      expect(result.derived_purchase_inputs_changed?).to be(false)
    end
  end
end
