require 'rails_helper'

RSpec.describe Amounts::Resolver do
  let(:computed) do
    {
      subtotal: 99,
      tax: 9,
      total: 108,
      tax_rate: BigDecimal('0.1')
    }
  end

  let(:receipt) do
    {
      subtotal_amount: 1_000,
      tax_amount: 100,
      total_amount: 1_100,
      tax_rate: BigDecimal('0.1')
    }
  end

  def resolve(context:, items: [], tax_details: [], receipt_values: receipt)
    described_class.new(
      computed: computed,
      receipt: receipt_values,
      context: context,
      items: items,
      tax_details: tax_details
    ).call
  end

  it 'uses computed values in analysis context even when receipt values exist' do
    result = resolve(context: :analysis)

    expect(result).to eq(computed)
  end

  it 'uses computed values in edit_save context when items exist' do
    result = resolve(
      context: :edit_save,
      items: [
        { line_total: 108, tax_rate: BigDecimal('0.1') }
      ]
    )

    expect(result).to eq(computed)
  end

  it 'preserves receipt values in edit_save context when no items exist' do
    result = resolve(context: :edit_save, items: [])

    expect(result).to eq(
      subtotal: 1_000,
      tax: 100,
      total: 1_100,
      tax_rate: BigDecimal('0.1')
    )
  end

  it 'uses computed values in manual context when items exist' do
    result = resolve(
      context: :manual,
      items: [
        { line_total: 108, tax_rate: BigDecimal('0.1') }
      ]
    )

    expect(result).to eq(computed)
  end

  it 'preserves receipt values in manual context when no items exist' do
    result = resolve(context: :manual, items: [])

    expect(result).to eq(
      subtotal: 1_000,
      tax: 100,
      total: 1_100,
      tax_rate: BigDecimal('0.1')
    )
  end

  it 'falls back to computed values for blank receipt values when preserving receipt input' do
    result = resolve(
      context: :manual,
      items: [],
      receipt_values: {
        total_amount: 1_100,
        subtotal_amount: nil,
        tax_amount: nil,
        tax_rate: nil
      }
    )

    expect(result).to eq(
      subtotal: 99,
      tax: 9,
      total: 1_100,
      tax_rate: BigDecimal('0.1')
    )
  end

  it 'treats unknown context as analysis' do
    result = resolve(context: :unexpected, items: [])

    expect(result).to eq(computed)
  end
end
