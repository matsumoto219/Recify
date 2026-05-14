require 'rails_helper'

RSpec.describe Amounts::TaxDetailAggregator do
  def aggregate(items)
    described_class.new(items: items).call
  end

  it 'does not generate tax details from measurement unit without line_total' do
    result = aggregate([
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit: 'kg', line_total: nil, tax_rate: BigDecimal('0.1') }
    ])

    expect(result).to be_empty
  end

  it 'generates tax details from countable unit without line_total' do
    result = aggregate([
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit: '個', line_total: nil, tax_rate: BigDecimal('0.1') }
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
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit: 'kg', line_total: 4_320, tax_rate: BigDecimal('0.1') }
    ])

    aggregate_failures do
      expect(result.size).to eq(1)
      expect(result.first[:net_amount]).to eq(3_928)
      expect(result.first[:amount]).to eq(392)
    end
  end
end
