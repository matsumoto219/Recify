require 'rails_helper'

RSpec.describe Amounts::ItemTotalAggregator do
  def aggregate(items)
    described_class.new(items: items).call
  end

  it 'treats line_total as the authoritative row total when present' do
    result = aggregate([
      { price: 300, quantity: 2, line_total: 500 }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(500)
      expect(result[:items].first[:line_total]).to eq(500)
      expect(result[:items].first[:original_line_total]).to eq(500)
    end
  end

  it 'treats explicit zero line_total as the authoritative row total' do
    result = aggregate([
      { price: 500, quantity: 1, line_total: 0 }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(0)
      expect(result[:items].first[:line_total]).to eq(0)
      expect(result[:items].first[:original_line_total]).to eq(0)
    end
  end

  it 'fills line_total from price multiplied by quantity when line_total is absent' do
    result = aggregate([
      { price: 250, quantity: 2, quantity_unit: '個', line_total: nil }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(500)
      expect(result[:items].first[:line_total]).to eq(500)
      expect(result[:items].first[:original_line_total]).to eq(500)
    end
  end

  it 'fills line_total from price multiplied by decimal quantity when line_total is absent' do
    result = aggregate([
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit: '個', line_total: nil }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(4_320)
      expect(result[:items].first[:quantity]).to eq(BigDecimal('0.300'))
      expect(result[:items].first[:line_total]).to eq(4_320)
      expect(result[:items].first[:original_line_total]).to eq(4_320)
    end
  end

  it 'parses decimal comma quantity as decimal when filling line_total' do
    result = aggregate([
      { price: 14_400, quantity: '0,300', quantity_unit: '個', line_total: nil }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(4_320)
      expect(result[:items].first[:quantity]).to eq(BigDecimal('0.300'))
      expect(result[:items].first[:line_total]).to eq(4_320)
    end
  end

  it 'parses comma separated amount strings as yen amounts' do
    result = aggregate([
      { price: '1,234', quantity: 2, quantity_unit: '個', line_total: nil }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(2_468)
      expect(result[:items].first[:line_total]).to eq(2_468)
    end
  end

  it 'does not fill line_total for measurement unit when line_total is absent' do
    result = aggregate([
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit: 'kg', line_total: nil }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(0)
      expect(result[:items].first[:quantity]).to eq(BigDecimal('0.300'))
      expect(result[:items].first[:line_total]).to eq(0)
      expect(result[:items].first[:original_line_total]).to eq(0)
    end
  end

  it 'keeps explicit line_total for measurement unit' do
    result = aggregate([
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit: 'kg', line_total: 4_320 }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(4_320)
      expect(result[:items].first[:quantity]).to eq(BigDecimal('0.300'))
      expect(result[:items].first[:line_total]).to eq(4_320)
      expect(result[:items].first[:original_line_total]).to eq(4_320)
    end
  end

  it 'does not fill line_total for unknown unit when line_total is absent' do
    result = aggregate([
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit: '束', line_total: nil }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(0)
      expect(result[:items].first[:line_total]).to eq(0)
      expect(result[:items].first[:original_line_total]).to eq(0)
    end
  end

  it 'keeps empty amount rows at zero when neither line_total nor price is present' do
    result = aggregate([
      { price: nil, quantity: 1, line_total: nil }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(0)
      expect(result[:items].first[:line_total]).to eq(0)
      expect(result[:items].first[:original_line_total]).to eq(0)
    end
  end
end
