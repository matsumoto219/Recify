require 'rails_helper'

RSpec.describe Receipts::Processing::Pipeline::FinalizeStep do
  subject(:finalize_step) do
    described_class.new(receipt: build_stubbed(:receipt), decision: instance_double(Receipts::Processing::Contracts::FinalizeDecision))
  end

  def apply(source_item, calculated_item)
    finalize_step.send(:apply_amount_item_totals, [ source_item ], [ calculated_item ]).sole
  end

  def receipt_amounts(source_item:, calculated_item:, source_receipt:, resolved:)
    finalize_step.send(
      :receipt_amount_attributes_for,
      {
        receipt_attributes: source_receipt,
        receipt_items_attributes: [ source_item ]
      },
      {
        resolved: resolved,
        computed: { items: [ calculated_item ] }
      }
    )
  end

  it '根拠のないmeasurement欠損金額をAmount内部の0円で永続化しない' do
    item = apply(
      {
        price: 140,
        quantity: BigDecimal('8.12'),
        quantity_unit_code: 'liter',
        quantity_unit_status: 'known',
        original_line_total: nil,
        line_total: nil
      },
      {
        price: 140,
        quantity: BigDecimal('8.12'),
        quantity_unit_code: 'liter',
        amount_line_total_present: false,
        original_line_total: 0,
        line_total: 0
      }
    )

    expect(item).to include(original_line_total: nil, line_total: nil)
  end

  it 'unknown OCR unitのstorage placeholderをcount formulaへ昇格しない' do
    item = apply(
      {
        price: 180,
        quantity: BigDecimal('2'),
        quantity_unit_code: 'each',
        quantity_unit_status: 'unknown',
        original_line_total: nil,
        line_total: nil
      },
      {
        price: 180,
        quantity: BigDecimal('2'),
        quantity_unit_code: 'each',
        amount_line_total_present: false,
        original_line_total: 360,
        line_total: 360
      }
    )

    expect(item).to include(original_line_total: nil, line_total: nil)
  end

  it 'known countable itemの既存fallback金額は永続化する' do
    item = apply(
      {
        price: 180,
        quantity: BigDecimal('2'),
        quantity_unit_code: 'each',
        quantity_unit_status: 'known',
        original_line_total: nil,
        line_total: nil
      },
      {
        price: 180,
        quantity: BigDecimal('2'),
        quantity_unit_code: 'each',
        amount_line_total_present: false,
        original_line_total: 360,
        line_total: 360
      }
    )

    expect(item).to include(original_line_total: 360, line_total: 360)
  end

  it 'measurement金額が未確定でもstrongly attributedなOCR receipt amountを0で上書きしない' do
    amounts = receipt_amounts(
      source_item: {
        quantity_unit_code: 'liter',
        quantity_unit_status: 'known',
        original_line_total: nil,
        line_total: nil
      },
      calculated_item: {
        amount_line_total_present: false,
        original_line_total: 0,
        line_total: 0
      },
      source_receipt: {
        total_amount: 1_137,
        subtotal_amount: 1_053,
        tax_amount: 84,
        tax_rate: BigDecimal('0.08')
      },
      resolved: { total: 0, subtotal: 0, tax: 0, tax_rate: nil }
    )

    expect(amounts).to eq(
      total_amount: 1_137,
      subtotal_amount: 1_053,
      tax_amount: 84,
      tax_rate: BigDecimal('0.08')
    )
  end

  it 'measurement明細とreceipt amountの両方が欠損した時にAmount内部の0円を永続化しない' do
    amounts = receipt_amounts(
      source_item: {
        quantity_unit_code: 'liter',
        quantity_unit_status: 'known',
        original_line_total: nil,
        line_total: nil
      },
      calculated_item: {
        amount_line_total_present: false,
        original_line_total: 0,
        line_total: 0
      },
      source_receipt: {
        total_amount: nil,
        subtotal_amount: nil,
        tax_amount: nil,
        tax_rate: nil
      },
      resolved: { total: 0, subtotal: 0, tax: 0, tax_rate: nil }
    )

    expect(amounts).to eq(
      total_amount: nil,
      subtotal_amount: nil,
      tax_amount: nil,
      tax_rate: nil
    )
  end

  it 'unknown unit明細とreceipt amountの両方が欠損した時にeach仮値の合計を永続化しない' do
    amounts = receipt_amounts(
      source_item: {
        quantity_unit_code: 'each',
        quantity_unit_status: 'unknown',
        original_line_total: nil,
        line_total: nil
      },
      calculated_item: {
        amount_line_total_present: false,
        original_line_total: 360,
        line_total: 360
      },
      source_receipt: {
        total_amount: nil,
        subtotal_amount: nil,
        tax_amount: nil,
        tax_rate: nil
      },
      resolved: { total: 360, subtotal: 360, tax: 0, tax_rate: nil }
    )

    expect(amounts).to eq(
      total_amount: nil,
      subtotal_amount: nil,
      tax_amount: nil,
      tax_rate: nil
    )
  end

  it 'item amountが確定している通常経路はAmount resolvedを採用する' do
    amounts = receipt_amounts(
      source_item: {
        quantity_unit_code: 'each',
        quantity_unit_status: 'known',
        original_line_total: 360,
        line_total: 360
      },
      calculated_item: {
        amount_line_total_present: true,
        original_line_total: 360,
        line_total: 360
      },
      source_receipt: { total_amount: 400, subtotal_amount: nil, tax_amount: nil, tax_rate: nil },
      resolved: { total: 360, subtotal: 327, tax: 33, tax_rate: BigDecimal('0.1') }
    )

    expect(amounts).to eq(
      total_amount: 360,
      subtotal_amount: 327,
      tax_amount: 33,
      tax_rate: BigDecimal('0.1')
    )
  end
end
