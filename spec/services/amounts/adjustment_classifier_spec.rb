require 'rails_helper'

RSpec.describe Amounts::AdjustmentClassifier do
  it 'キャッシュレス還元を購入値引きではなく支払調整に分類する' do
    result = described_class.call(
      kind: 'other',
      label: 'キャッシュレス還元額',
      source_text: 'キャッシュレス還元額 -22',
      sign: 'discount',
      amount: 22,
      source: 'ocr'
    )

    expect(result).to include(
      effect: :payment_adjustment,
      signed_amount: -22,
      warnings: []
    )
  end

  it 'クーポン値引きを購入調整として分類する' do
    result = described_class.call(
      kind: 'coupon',
      sign: 'discount',
      amount: 100,
      source: 'ocr'
    )

    expect(result).to include(
      effect: :non_taxable_adjustment,
      signed_amount: -100
    )
  end
end
