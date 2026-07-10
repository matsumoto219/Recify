require 'rails_helper'

RSpec.describe Amounts::AdjustmentTaxRateResolver do
  def resolve(adjustments:, items:, tax_details: [])
    described_class.call(
      adjustments: adjustments,
      items: items,
      tax_details: tax_details
    )
  end

  it '単一課税率だけの明細では未指定の購入調整へ税率を継承する' do
    result = resolve(
      adjustments: [ { kind: 'coupon', sign: 'discount', amount: 10 } ],
      items: [ { line_total: 100, tax_rate: BigDecimal('0.10') } ]
    ).sole

    expect(result).to include(
      tax_rate: BigDecimal('0.10'),
      tax_rate_present: true,
      tax_rate_source: 'inherited_single_rate'
    )
  end

  it '明示0%を未指定と区別して維持する' do
    result = resolve(
      adjustments: [ { kind: 'coupon', sign: 'discount', amount: 10, tax_rate: BigDecimal('0') } ],
      items: [ { line_total: 100, tax_rate: BigDecimal('0.10') } ]
    ).sole

    expect(result).to include(
      tax_rate: BigDecimal('0'),
      tax_rate_present: true,
      tax_rate_source: 'explicit'
    )
  end

  it '複数税率では購入調整の税率を推測しない' do
    result = resolve(
      adjustments: [ { kind: 'coupon', sign: 'discount', amount: 10 } ],
      items: [
        { line_total: 100, tax_rate: BigDecimal('0.08') },
        { line_total: 100, tax_rate: BigDecimal('0.10') }
      ]
    ).sole

    expect(result).to include(
      tax_rate: nil,
      tax_rate_present: false,
      tax_rate_source: 'unknown'
    )
  end

  it '課税明細と非課税明細の混在では購入調整の税率を推測しない' do
    result = resolve(
      adjustments: [ { kind: 'coupon', sign: 'discount', amount: 10 } ],
      items: [
        { line_total: 100, tax_rate: BigDecimal('0.10') },
        { line_total: 100, tax_rate: BigDecimal('0') }
      ]
    ).sole

    expect(result[:tax_rate]).to be_nil
    expect(result[:tax_rate_source]).to eq('unknown')
  end

  it '印字税詳細が明細の単一税率と矛盾する場合は継承しない' do
    result = resolve(
      adjustments: [ { kind: 'coupon', sign: 'discount', amount: 10 } ],
      items: [ { line_total: 100, tax_rate: BigDecimal('0.10') } ],
      tax_details: [ { rate: BigDecimal('0.08'), amount: 7 } ]
    ).sole

    expect(result[:tax_rate]).to be_nil
    expect(result[:tax_rate_source]).to eq('unknown')
  end

  it '支払調整には購入税率を継承しない' do
    result = resolve(
      adjustments: [ { kind: 'point_usage', sign: 'discount', amount: 10 } ],
      items: [ { line_total: 100, tax_rate: BigDecimal('0.10') } ]
    ).sole

    expect(result).to include(
      tax_rate: nil,
      tax_rate_present: false,
      tax_rate_source: 'not_applicable'
    )
  end
end
