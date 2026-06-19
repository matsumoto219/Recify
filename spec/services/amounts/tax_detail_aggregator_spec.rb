require 'rails_helper'

RSpec.describe Amounts::TaxDetailAggregator do
  def aggregate(items)
    described_class.new(items: items).call
  end

  it 'tax_rateありのsurcharge adjustmentを税率別集計へ加算する' do
    result = described_class.new(
      items: [
        { line_total: 1_100, tax_rate: BigDecimal('0.1') }
      ],
      adjustments: [
        { kind: 'delivery_fee', sign: 'surcharge', amount: 550, tax_rate: BigDecimal('0.1') }
      ],
      rounding_mode: :floor
    ).call

    expect(result).to include(
      include(rate: BigDecimal('0.1'), net_amount: 1_500, amount: 150)
    )
  end

  it 'tax_rateありのdiscount adjustmentを税率別集計から減算する' do
    result = described_class.new(
      items: [
        { line_total: 1_000, tax_rate: BigDecimal('0.1') }
      ],
      adjustments: [
        { kind: 'coupon', sign: 'discount', amount: 110, tax_rate: BigDecimal('0.1') }
      ],
      rounding_mode: :floor
    ).call

    expect(result).to include(
      include(rate: BigDecimal('0.1'), net_amount: 810, amount: 80)
    )
  end

  it 'point_usage adjustmentは税率別集計から除外する' do
    result = described_class.new(
      items: [
        { line_total: 1_100, tax_rate: BigDecimal('0.1') }
      ],
      adjustments: [
        { kind: 'point_usage', sign: 'discount', amount: 500, tax_rate: BigDecimal('0.1') }
      ],
      rounding_mode: :floor
    ).call

    expect(result).to include(
      include(rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100)
    )
  end

  it 'does not generate tax details from measurement unit without line_total' do
    result = aggregate([
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit_code: 'kilogram', line_total: nil, tax_rate: BigDecimal('0.1') }
    ])

    expect(result).to be_empty
  end

  it 'does not generate tax details from measurement unit code without line_total' do
    result = aggregate([
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit_code: 'kilogram', line_total: nil, tax_rate: BigDecimal('0.1') }
    ])

    expect(result).to be_empty
  end

  it 'generates tax details from countable unit without line_total' do
    result = aggregate([
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit_code: 'each', line_total: nil, tax_rate: BigDecimal('0.1') }
    ])

    aggregate_failures do
      expect(result.size).to eq(1)
      expect(result.first[:rate]).to eq(BigDecimal('0.1'))
      expect(result.first[:net_amount]).to eq(3_928)
      expect(result.first[:amount]).to eq(392)
    end
  end

  it 'generates tax details from countable unit code without line_total' do
    result = aggregate([
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit_code: 'each', line_total: nil, tax_rate: BigDecimal('0.1') }
    ])

    aggregate_failures do
      expect(result.size).to eq(1)
      expect(result.first[:rate]).to eq(BigDecimal('0.1'))
      expect(result.first[:net_amount]).to eq(3_928)
      expect(result.first[:amount]).to eq(392)
    end
  end

  it 'uses explicit line_total for measurement unit' do
    result = aggregate([
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit_code: 'kilogram', line_total: 4_320, tax_rate: BigDecimal('0.1') }
    ])

    aggregate_failures do
      expect(result.size).to eq(1)
      expect(result.first[:net_amount]).to eq(3_928)
      expect(result.first[:amount]).to eq(392)
    end
  end
end
