require 'rails_helper'

RSpec.describe Amounts::AdjustmentTotalAggregator do
  def aggregate(adjustments:, items: [], receipt_tax_basis: :total_includes_tax)
    described_class.new(
      adjustments: adjustments,
      items: items,
      rounding_mode: :floor,
      receipt_tax_basis: receipt_tax_basis
    ).call
  end

  it 'surcharge kindsを加算として集計する' do
    result = aggregate(
      adjustments: [
        { kind: 'service_charge', sign: 'surcharge', amount: 486 },
        { kind: 'delivery_fee', sign: 'surcharge', amount: 550 },
        { kind: 'bag_fee', sign: 'surcharge', amount: 10 }
      ]
    )

    aggregate_failures do
      expect(result[:surcharge_total]).to eq(1_046)
      expect(result[:discount_total]).to eq(0)
      expect(result[:receipt_total_delta]).to eq(1_046)
    end
  end

  it 'discount kindsを減算として集計する' do
    result = aggregate(
      adjustments: [
        { kind: 'receipt_discount', sign: 'discount', amount: 100 },
        { kind: 'coupon', sign: 'discount', amount: 50 },
        { kind: 'return_refund', sign: 'discount', amount: 980 }
      ]
    )

    aggregate_failures do
      expect(result[:surcharge_total]).to eq(0)
      expect(result[:discount_total]).to eq(1_130)
      expect(result[:receipt_total_delta]).to eq(-1_130)
    end
  end

  it 'tax_rateありadjustmentを税率別集計に含める' do
    result = aggregate(
      adjustments: [
        { kind: 'delivery_fee', sign: 'surcharge', amount: 550, tax_rate: BigDecimal('0.1') },
        { kind: 'coupon', sign: 'discount', amount: 110, tax_rate: BigDecimal('0.1') }
      ]
    )

    aggregate_failures do
      expect(result[:taxable_surcharge_total_by_rate][BigDecimal('0.1')]).to eq(550)
      expect(result[:taxable_discount_total_by_rate][BigDecimal('0.1')]).to eq(110)
      expect(result[:taxable_delta_by_rate][BigDecimal('0.1')]).to eq(440)
      expect(result[:total_delta]).to eq(440)
      expect(result[:tax_delta]).to eq(40)
      expect(result[:subtotal_delta]).to eq(400)
    end
  end

  it 'tax_rateなしadjustmentは合計整合に含めつつ税率不明として集計する' do
    result = aggregate(
      adjustments: [
        { kind: 'handling_fee', sign: 'surcharge', amount: 300 }
      ]
    )

    aggregate_failures do
      expect(result[:receipt_total_delta]).to eq(300)
      expect(result[:total_delta]).to eq(300)
      expect(result[:tax_rate_missing_adjustment_total]).to eq(300)
      expect(result[:taxable_delta_by_rate]).to be_empty
    end
  end

  it 'point_usageは支払調整として扱い税計算・合計計算から除外する' do
    result = aggregate(
      adjustments: [
        { kind: 'point_usage', sign: 'discount', amount: 500, tax_rate: BigDecimal('0.1') }
      ]
    )

    aggregate_failures do
      expect(result[:payment_adjustment_total]).to eq(-500)
      expect(result[:receipt_total_delta]).to eq(0)
      expect(result[:taxable_delta_by_rate]).to be_empty
    end
  end

  it 'manual sourceのotherは不確実扱いにしない' do
    result = aggregate(
      adjustments: [
        { kind: 'other', sign: 'surcharge', amount: 100, source: 'manual' }
      ]
    )

    expect(result[:uncertain_adjustments]).to be_empty
  end

  it 'ai/ocr sourceのotherは不確実として返す' do
    result = aggregate(
      adjustments: [
        { kind: 'other', sign: 'surcharge', amount: 100, source: 'ai' },
        { kind: 'other', sign: 'discount', amount: 50, source: 'ocr' }
      ]
    )

    expect(result[:uncertain_adjustments].size).to eq(2)
  end

  it 'needs_review adjustmentはsourceに関係なく不確実として返す' do
    result = aggregate(
      adjustments: [
        { kind: 'delivery_fee', sign: 'surcharge', amount: 50, source: 'manual', needs_review: true },
        { kind: 'delivery_fee', sign: 'surcharge', amount: 50, needs_review: true }
      ]
    )

    expect(result[:uncertain_adjustments].size).to eq(2)
  end
end
