require 'rails_helper'

RSpec.describe Receipts::Editing::AmountResultApplicator do
  let(:tax_detail) { instance_double(ReceiptTaxDetail, id: 7) }
  let(:receipt) { instance_double(Receipt, receipt_tax_details: [ tax_detail ]) }
  let(:profile_snapshot) { { 'schema_version' => 'amount_profile_v1' } }
  let(:amount_result) do
    {
      resolved: { subtotal: 900, tax: 100, total: 1_000, tax_rate: BigDecimal('0.1') },
      computed: {
        items: [
          {
            'quantity' => BigDecimal('2'),
            price: 500,
            line_total: 1_000,
            original_line_total: 1_100,
            discount_amount: 100,
            discount_rate: BigDecimal('0.0909')
          }
        ]
      },
      tax_details: [
        { description: '10%対象', amount: 100, rate: BigDecimal('0.1'), net_amount: 900 }
      ]
    }
  end

  before do
    allow(ReceiptAmountService).to receive(:calculation_profile_snapshot)
      .with(amount_result)
      .and_return(profile_snapshot)
  end

  it 'applies resolved amounts, item totals, profile, and tax details in the existing shape' do
    attributes = {
      'receipt_items_attributes' => {
        '0' => { 'quantity' => '1', 'price' => '400' },
        '1' => { 'id' => '8', '_destroy' => '1', 'line_total' => '999' }
      }
    }

    result = described_class.call(
      receipt: receipt,
      attributes: attributes,
      amount_result: amount_result,
      context: :manual,
      change_set: nil,
      tax_details_recalculated: false
    )

    aggregate_failures do
      expect(result).to equal(attributes)
      expect(attributes).to include(
        'subtotal_amount' => 900,
        'tax_amount' => 100,
        'total_amount' => 1_000,
        'tax_rate' => BigDecimal('0.1'),
        'amount_calculation_profile' => profile_snapshot
      )
      expect(attributes.dig('receipt_items_attributes', '0')).to include(
        'quantity' => BigDecimal('2'),
        'price' => 500,
        'line_total' => 1_000,
        'original_line_total' => 1_100,
        'discount_amount' => 100,
        'discount_rate' => BigDecimal('0.0909')
      )
      expect(attributes.dig('receipt_items_attributes', '1', 'line_total')).to eq('999')
      expect(attributes['receipt_tax_details_attributes']).to eq([
        { 'id' => 7, '_destroy' => '1' },
        {
          'description' => '10%対象',
          'amount' => 100,
          'rate' => BigDecimal('0.1'),
          'net_amount' => 900
        }
      ])
    end
  end

  it 'does not replace tax details for an unchanged edit-save result' do
    attributes = { 'receipt_tax_details_attributes' => { '0' => { 'id' => '7', 'amount' => '80' } } }
    change_set = instance_double(Receipts::Editing::ChangeSet::Result, purchase_amounts_changed?: false)

    described_class.call(
      receipt: receipt,
      attributes: attributes,
      amount_result: amount_result,
      context: :edit_save,
      change_set: change_set,
      tax_details_recalculated: false
    )

    expect(attributes['receipt_tax_details_attributes']).to eq('0' => { 'id' => '7', 'amount' => '80' })
  end

  it 'applies normalized source items instead of candidate-derived items for edit-save persistence' do
    attributes = {
      'receipt_items_attributes' => {
        '0' => {
          'quantity' => '2',
          'price' => '128',
          'line_total' => '256',
          'original_line_total' => '128'
        }
      }
    }
    amount_result[:computed][:source_items] = [
      {
        quantity: BigDecimal('2'),
        price: 128,
        line_total: 256,
        original_line_total: 256
      }
    ]
    result_snapshot = amount_result.deep_dup

    described_class.call(
      receipt: receipt,
      attributes: attributes,
      amount_result: amount_result,
      context: :edit_save,
      change_set: nil,
      tax_details_recalculated: false
    )

    aggregate_failures do
      expect(attributes.dig('receipt_items_attributes', '0')).to include(
        'quantity' => BigDecimal('2'),
        'price' => 128,
        'line_total' => 256,
        'original_line_total' => 256
      )
      expect(amount_result).to eq(result_snapshot)
    end
  end

  it 'keeps an empty normalized source item collection instead of falling back to candidate items' do
    attributes = {
      'receipt_items_attributes' => {
        '0' => { 'quantity' => '1', 'price' => '128', 'line_total' => '128' }
      }
    }
    amount_result[:computed][:source_items] = []

    described_class.call(
      receipt: receipt,
      attributes: attributes,
      amount_result: amount_result,
      context: :edit_save,
      change_set: nil,
      tax_details_recalculated: false
    )

    expect(attributes.dig('receipt_items_attributes', '0')).to eq(
      'quantity' => '1',
      'price' => '128',
      'line_total' => '128'
    )
  end

  it 'keeps candidate-derived item projection for analysis' do
    attributes = {
      'receipt_items_attributes' => {
        '0' => { 'quantity' => '2', 'price' => '128', 'line_total' => '256' }
      }
    }
    amount_result[:computed][:source_items] = [ { quantity: 2, price: 128, line_total: 256 } ]

    described_class.call(
      receipt: receipt,
      attributes: attributes,
      amount_result: amount_result,
      context: :analysis,
      change_set: nil,
      tax_details_recalculated: false
    )

    expect(attributes.dig('receipt_items_attributes', '0')).to include(
      'quantity' => BigDecimal('2'),
      'price' => 500,
      'line_total' => 1_000
    )
  end

  it 'replaces tax details when edit-save recalculation requires it' do
    attributes = {}
    change_set = instance_double(Receipts::Editing::ChangeSet::Result, purchase_amounts_changed?: false)

    described_class.call(
      receipt: receipt,
      attributes: attributes,
      amount_result: amount_result,
      context: :edit_save,
      change_set: change_set,
      tax_details_recalculated: true
    )

    expect(attributes['receipt_tax_details_attributes']).to start_with({ 'id' => 7, '_destroy' => '1' })
  end

  it 'preserves existing item values when calculated optional values are absent' do
    attributes = {
      'receipt_items_attributes' => {
        '0' => {
          'quantity' => '3',
          'price' => '400',
          'line_total' => '1,200',
          'original_line_total' => '1,200'
        }
      }
    }
    amount_result[:computed][:items] = [ { quantity: nil, price: nil, line_total: nil } ]

    described_class.call(
      receipt: receipt,
      attributes: attributes,
      amount_result: amount_result,
      context: :edit_save,
      change_set: nil,
      tax_details_recalculated: false
    )

    expect(attributes.dig('receipt_items_attributes', '0')).to include(
      'quantity' => '3',
      'price' => '400',
      'line_total' => '1,200',
      'original_line_total' => '1,200'
    )
  end
end
