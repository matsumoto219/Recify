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
      { price: 250, quantity: 2, line_total: nil }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(500)
      expect(result[:items].first[:line_total]).to eq(500)
      expect(result[:items].first[:original_line_total]).to eq(500)
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
