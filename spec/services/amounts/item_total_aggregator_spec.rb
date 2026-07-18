require 'rails_helper'

RSpec.describe Amounts::ItemTotalAggregator do
  def aggregate(items, **options)
    described_class.new(items: items, **options).call
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
      { price: 250, quantity: 2, quantity_unit_code: 'each', line_total: nil }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(500)
      expect(result[:items].first[:line_total]).to eq(500)
      expect(result[:items].first[:original_line_total]).to eq(500)
    end
  end

  it 'fills line_total from quantity_unit_code when line_total is absent' do
    result = aggregate([
      { price: 250, quantity: 2, quantity_unit_code: 'each', line_total: nil }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(500)
      expect(result[:items].first[:line_total]).to eq(500)
      expect(result[:items].first[:original_line_total]).to eq(500)
    end
  end

  it 'fills line_total from price multiplied by decimal quantity when line_total is absent' do
    result = aggregate([
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit_code: 'each', line_total: nil }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(4_320)
      expect(result[:items].first[:quantity]).to eq(BigDecimal('0.300'))
      expect(result[:items].first[:line_total]).to eq(4_320)
      expect(result[:items].first[:original_line_total]).to eq(4_320)
    end
  end

  it 'keeps original_line_total as the pre-discount row total and line_total as the discounted row total' do
    result = aggregate([
      { price: nil, quantity: 2, quantity_unit_code: 'each', original_line_total: 600, discount_amount: 300, line_total: 300 }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(300)
      expect(result[:items].first[:original_line_total]).to eq(600)
      expect(result[:items].first[:discount_amount]).to eq(300)
      expect(result[:items].first[:line_total]).to eq(300)
    end
  end

  it 'preserves explicit discount_amount as authoritative in analysis context' do
    result = aggregate(
      [
        {
          quantity_unit_code: 'each',
          original_line_total: 271,
          discount_amount: 136,
          discount_rate: BigDecimal('0.5'),
          line_total: 135
        }
      ],
      context: :analysis,
      discount_rounding_mode: :floor
    )

    aggregate_failures do
      expect(result[:items].first[:discount_amount]).to eq(136)
      expect(result[:items].first[:line_total]).to eq(135)
    end
  end

  it 'uses discount_rate as authoritative in manual context with discount rounding' do
    result = aggregate(
      [
        {
          quantity_unit_code: 'each',
          original_line_total: 271,
          discount_amount: 135,
          discount_rate: BigDecimal('0.5'),
          line_total: 136
        }
      ],
      context: :manual,
      discount_rounding_mode: :round
    )

    aggregate_failures do
      expect(result[:items].first[:discount_amount]).to eq(136)
      expect(result[:items].first[:line_total]).to eq(135)
    end
  end

  it 'clears discount_amount when manual context submits blank discount_rate' do
    result = aggregate(
      [
        {
          quantity_unit_code: 'each',
          original_line_total: 310,
          discount_amount: 155,
          discount_rate: '',
          line_total: 155
        }
      ],
      context: :manual,
      discount_rounding_mode: :round
    )

    aggregate_failures do
      expect(result[:items].first[:discount_amount]).to be_nil
      expect(result[:items].first[:discount_rate]).to be_nil
      expect(result[:items].first[:line_total]).to eq(310)
    end
  end

  it 'preserves explicit zero discount_amount when manual context marks it as submitted' do
    result = aggregate(
      [
        {
          quantity_unit_code: 'each',
          original_line_total: 310,
          discount_amount: 0,
          amount_discount_amount_present: true,
          discount_rate: '',
          line_total: 310
        }
      ],
      context: :manual,
      discount_rounding_mode: :round
    )

    aggregate_failures do
      expect(result[:items].first[:discount_amount]).to eq(0)
      expect(result[:items].first[:discount_rate]).to be_nil
      expect(result[:items].first[:line_total]).to eq(310)
    end
  end

  it 'manual context ignores stale original_line_total when price and line_total are already tax included' do
    result = aggregate(
      [
        {
          price: 140,
          quantity: 1,
          quantity_unit_code: 'each',
          original_line_total: 130,
          line_total: 140,
          tax_rate: BigDecimal('0.08')
        }
      ],
      context: :manual
    )

    aggregate_failures do
      # 検算: 解析時の130円はOCR元値。手動再計算では税込正規化済みの140円を明細金額として使う。
      expect(result[:total]).to eq(140)
      expect(result[:items].first[:original_line_total]).to eq(140)
      expect(result[:items].first[:line_total]).to eq(140)
    end
  end

  it 'edit_saveではcountable itemの明示priceとquantityをstale hidden line_totalより優先する' do
    cases = [
      {
        price: 100,
        quantity: 1,
        quantity_unit_code: 'each',
        original_line_total: 100,
        line_total: 110,
        amount_price_present: true,
        amount_quantity_present: true,
        amount_line_total_present: true
      },
      {
        price: 100,
        quantity: 2,
        quantity_unit_code: 'each',
        original_line_total: 200,
        line_total: 120,
        amount_price_present: true,
        amount_quantity_present: true,
        amount_line_total_present: true
      }
    ]

    results = cases.map { |item| aggregate([ item ], context: :edit_save) }

    aggregate_failures do
      expect(results.map { |result| result[:total] }).to eq([ 100, 200 ])
      expect(results.map { |result| result[:items].first[:original_line_total] }).to eq([ 100, 200 ])
      expect(results.map { |result| result[:items].first[:line_total] }).to eq([ 100, 200 ])
    end
  end

  it 'edit_saveの未送信countable itemは保存済みgross line_totalの互換経路を維持する' do
    result = aggregate(
      [
        {
          price: 130,
          quantity: 1,
          quantity_unit_code: 'each',
          original_line_total: 130,
          line_total: 140,
          amount_price_present: false,
          amount_quantity_present: false,
          amount_line_total_present: false
        }
      ],
      context: :edit_save
    )

    aggregate_failures do
      expect(result[:total]).to eq(140)
      expect(result[:items].first[:original_line_total]).to eq(140)
      expect(result[:items].first[:line_total]).to eq(140)
    end
  end

  it 'edit_saveで無変更送信されたcountable itemも保存済みgross line_totalを維持する' do
    result = aggregate(
      [
        {
          price: 130,
          quantity: 1,
          quantity_unit_code: 'each',
          original_line_total: 130,
          line_total: 140,
          amount_price_present: true,
          amount_quantity_present: true,
          amount_line_total_present: true,
          amount_countable_source_changed: false,
          amount_line_total_changed: true,
          amount_persisted_item: true,
          amount_persisted_original_line_total: 130,
          amount_persisted_line_total: 140
        }
      ],
      context: :edit_save
    )

    aggregate_failures do
      expect(result[:total]).to eq(140)
      expect(result[:items].first[:original_line_total]).to eq(130)
      expect(result[:items].first[:line_total]).to eq(140)
    end
  end

  it 'edit_saveでsource不変の割引countable itemは保存済みamount投影を再計算しない' do
    result = aggregate(
      [
        {
          price: 100,
          quantity: 1,
          quantity_unit_code: 'each',
          original_line_total: 100,
          discount_rate: BigDecimal('0.1'),
          discount_amount: 10,
          line_total: 110,
          amount_countable_source_changed: false,
          amount_persisted_item: true,
          amount_persisted_original_line_total: 100,
          amount_persisted_discount_rate: BigDecimal('0.1'),
          amount_persisted_discount_amount: 10,
          amount_persisted_line_total: 110
        }
      ],
      context: :edit_save
    )

    expect(result[:items].first).to include(
      original_line_total: 100,
      discount_rate: BigDecimal('0.1'),
      discount_amount: 10,
      line_total: 110
    )
  end

  it 'edit_saveでもmeasurement itemの明示line_totalはpriceとquantityから上書きしない' do
    result = aggregate(
      [
        {
          price: 14_400,
          quantity: BigDecimal('0.300'),
          quantity_unit_code: 'kilogram',
          original_line_total: 4_320,
          line_total: 4_321
        }
      ],
      context: :edit_save
    )

    aggregate_failures do
      expect(result[:total]).to eq(4_321)
      expect(result[:items].first[:original_line_total]).to eq(4_321)
      expect(result[:items].first[:line_total]).to eq(4_321)
    end
  end

  it 'parses decimal comma quantity as decimal when filling line_total' do
    result = aggregate([
      { price: 14_400, quantity: '0,300', quantity_unit_code: 'each', line_total: nil }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(4_320)
      expect(result[:items].first[:quantity]).to eq(BigDecimal('0.300'))
      expect(result[:items].first[:line_total]).to eq(4_320)
    end
  end

  it 'parses comma separated amount strings as yen amounts' do
    result = aggregate([
      { price: '1,234', quantity: 2, quantity_unit_code: 'each', line_total: nil }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(2_468)
      expect(result[:items].first[:line_total]).to eq(2_468)
    end
  end

  it 'does not fill line_total for measurement unit when line_total is absent' do
    result = aggregate([
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit_code: 'kilogram', line_total: nil }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(0)
      expect(result[:items].first[:quantity]).to eq(BigDecimal('0.300'))
      expect(result[:items].first[:line_total]).to eq(0)
      expect(result[:items].first[:original_line_total]).to eq(0)
    end
  end

  it 'does not fill line_total for measurement unit code when line_total is absent' do
    result = aggregate([
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit_code: 'kilogram', line_total: nil }
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
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit_code: 'kilogram', line_total: 4_320 }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(4_320)
      expect(result[:items].first[:quantity]).to eq(BigDecimal('0.300'))
      expect(result[:items].first[:line_total]).to eq(4_320)
      expect(result[:items].first[:original_line_total]).to eq(4_320)
    end
  end

  it 'normalizes unknown unit to the default code before filling line_total' do
    result = aggregate([
      { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit_code: 'each', line_total: nil }
    ])

    aggregate_failures do
      expect(result[:total]).to eq(4_320)
      expect(result[:items].first[:line_total]).to eq(4_320)
      expect(result[:items].first[:original_line_total]).to eq(4_320)
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

  it 'manual contextでは送信された不正quantityを1へ補正しない' do
    result = aggregate(
      [
        {
          price: 100,
          quantity: nil,
          amount_quantity_present: true,
          quantity_unit_code: 'each',
          line_total: 100
        }
      ],
      context: :edit_save
    )

    aggregate_failures do
      expect(result[:items].first[:quantity]).to eq(BigDecimal('0'))
      expect(result[:items].first[:line_total]).to eq(0)
    end
  end

  it 'manual contextでは未入力quantityだけを1へ補完する' do
    result = aggregate(
      [
        {
          price: 100,
          quantity: nil,
          amount_quantity_present: false,
          quantity_unit_code: 'each',
          line_total: nil
        }
      ],
      context: :manual
    )

    aggregate_failures do
      expect(result[:items].first[:quantity]).to eq(BigDecimal('1'))
      expect(result[:items].first[:line_total]).to eq(100)
    end
  end
end
