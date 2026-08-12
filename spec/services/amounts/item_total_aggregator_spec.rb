require 'rails_helper'

RSpec.describe Amounts::ItemTotalAggregator do
  def aggregate(items, **options)
    described_class.new(items: items, **options).call
  end

  def reference_item(**overrides)
    {
      pricing_source_kind: 'reference_quantity_price',
      reference_price_amount: BigDecimal('120'),
      reference_quantity: BigDecimal('500'),
      reference_quantity_unit_code: 'milliliter',
      reference_quantity_unit_raw: nil,
      reference_price_tax_inclusion: 'gross',
      quantity: BigDecimal('1.5'),
      quantity_unit_code: 'liter',
      quantity_unit_raw: nil,
      price: 999,
      original_line_total: 998,
      line_total: 997
    }.merge(overrides)
  end

  describe 'reference quantity price authority' do
    it '全14 canonical unitをreference formulaのAmount境界へ通す' do
      all_unit_codes = %w[
        each item piece bag sheet unit box set
        gram kilogram milligram liter milliliter cubic_centimeter
      ]

      aggregate_failures do
        all_unit_codes.each do |code|
          result = aggregate(
            [
              reference_item(
                reference_price_amount: '100',
                reference_quantity: '2',
                reference_quantity_unit_code: code,
                quantity: '3',
                quantity_unit_code: code
              )
            ],
            context: :edit_save
          )
          normalized = result[:items].first

          expect(result[:total]).to eq(150), code
          expect(normalized).to include(
            original_line_total: 150,
            line_total: 150,
            pricing_source_kind: 'reference_quantity_price',
            reference_quantity_unit_code: code,
            quantity_unit_code: code,
            reference_price_tax_inclusion: 'gross'
          ), code
        end
      end
    end

    it 'mass・volumeの異なるscaleを参照単位側へexact換算する' do
      vectors = [
        {
          label: '1.8円/1g × 0.85kg',
          reference_price_amount: '1.8',
          reference_quantity: '1',
          reference_unit_code: 'gram',
          purchased_quantity: '0.85',
          purchased_unit_code: 'kilogram',
          expected: 1_530
        },
        {
          label: '1800円/1kg × 850g',
          reference_price_amount: '1800',
          reference_quantity: '1',
          reference_unit_code: 'kilogram',
          purchased_quantity: '850',
          purchased_unit_code: 'gram',
          expected: 1_530
        },
        {
          label: '0.9円/1mg × 1.2g',
          reference_price_amount: '0.9',
          reference_quantity: '1',
          reference_unit_code: 'milligram',
          purchased_quantity: '1.2',
          purchased_unit_code: 'gram',
          expected: 1_080
        },
        {
          label: '120円/500ml × 1.5L',
          reference_price_amount: '120',
          reference_quantity: '500',
          reference_unit_code: 'milliliter',
          purchased_quantity: '1.5',
          purchased_unit_code: 'liter',
          expected: 360
        },
        {
          label: '140円/1L × 8120ml',
          reference_price_amount: '140',
          reference_quantity: '1',
          reference_unit_code: 'liter',
          purchased_quantity: '8120',
          purchased_unit_code: 'milliliter',
          expected: 1_137
        },
        {
          label: '140円/10L × 8120cc',
          reference_price_amount: '140',
          reference_quantity: '10',
          reference_unit_code: 'liter',
          purchased_quantity: '8120',
          purchased_unit_code: 'cubic_centimeter',
          expected: 114
        },
        {
          label: '120円/500cc × 1500ml',
          reference_price_amount: '120',
          reference_quantity: '500',
          reference_unit_code: 'cubic_centimeter',
          purchased_quantity: '1500',
          purchased_unit_code: 'milliliter',
          expected: 360
        }
      ]

      aggregate_failures do
        vectors.each do |vector|
          result = aggregate(
            [
              reference_item(
                reference_price_amount: vector.fetch(:reference_price_amount),
                reference_quantity: vector.fetch(:reference_quantity),
                reference_quantity_unit_code: vector.fetch(:reference_unit_code),
                quantity: vector.fetch(:purchased_quantity),
                quantity_unit_code: vector.fetch(:purchased_unit_code)
              )
            ],
            context: :edit_save
          )

          expect(result[:total]).to eq(vector.fetch(:expected)), vector.fetch(:label)
          expect(result[:items].first[:original_line_total]).to eq(vector.fetch(:expected)), vector.fetch(:label)
        end
      end
    end

    it 'stale price・original_line_total・line_totalを無視してexact extensionを割引前金額にする' do
      result = aggregate([ reference_item ], context: :edit_save)

      expect(result).to include(total: 360)
      expect(result[:items].first).to include(
        price: 999,
        original_line_total: 360,
        discount_amount: nil,
        line_total: 360,
        reference_price_tax_inclusion: 'gross'
      )
    end

    it 'projected extensionへ既存discount rateを1回だけ適用する' do
      result = aggregate(
        [
          reference_item(
            discount_rate: BigDecimal('0.1'),
            discount_amount: 999,
            amount_discount_amount_present: true
          )
        ],
        context: :edit_save,
        discount_rounding_mode: :round
      )

      expect(result).to include(total: 324)
      expect(result[:items].first).to include(
        original_line_total: 360,
        discount_rate: BigDecimal('0.1'),
        discount_amount: 36,
        line_total: 324
      )
    end

    it 'gross/net metadataをtax projectionせずformula結果と一緒に保持する' do
      items = %w[gross net].map do |tax_inclusion|
        reference_item(reference_price_tax_inclusion: tax_inclusion)
      end

      result = aggregate(items, context: :edit_save)

      aggregate_failures do
        expect(result[:total]).to eq(720)
        expect(result[:items].map { |item| item[:line_total] }).to eq([ 360, 360 ])
        expect(result[:items].map { |item| item[:reference_price_tax_inclusion] }).to eq(%w[gross net])
      end
    end

    it 'manualはgrossのみ、edit_save・analysisはgross/netを受理する' do
      manual_gross = aggregate(
        [ reference_item(reference_price_tax_inclusion: 'gross') ],
        context: :manual
      )

      aggregate_failures do
        expect(manual_gross[:total]).to eq(360)
        expect {
          aggregate(
            [ reference_item(reference_price_tax_inclusion: 'net') ],
            context: :manual
          )
        }.to raise_error(Amounts::ItemPricingSource::InvalidContractError)

        %i[edit_save analysis].product(%w[gross net]).each do |context, tax_inclusion|
          result = aggregate(
            [ reference_item(reference_price_tax_inclusion: tax_inclusion) ],
            context: context
          )

          expect(result[:total]).to eq(360), "#{context}: #{tax_inclusion}"
          expect(result[:items].first[:reference_price_tax_inclusion]).to eq(tax_inclusion),
            "#{context}: #{tax_inclusion}"
        end
      end
    end

    it 'alias・raw fallback・unknown unitをcanonical formula sourceにしない' do
      invalid_items = [
        reference_item(quantity_unit_code: 'L'),
        reference_item(reference_quantity_unit_code: 'ml'),
        reference_item(quantity_unit_raw: ''),
        reference_item(reference_quantity_unit_raw: ''),
        reference_item(quantity_unit_code: 'each', quantity_unit_raw: 'fluid_ounce'),
        reference_item(reference_quantity_unit_code: nil, reference_quantity_unit_raw: 'fluid_ounce'),
        reference_item(quantity_unit_code: 'unknown')
      ]

      invalid_items.each do |item|
        expect { aggregate([ item ], context: :edit_save) }
          .to raise_error(Amounts::ItemQuantitySemantics::InvalidFormulaSourceError), item.inspect
      end
    end

    it 'reference authority以外ではexplicit・legacy measurement・count formulaの現行契約を維持する' do
      items = [
        {
          pricing_source_kind: 'explicit_line_total',
          price: 120,
          quantity: BigDecimal('1.5'),
          quantity_unit_code: 'liter',
          line_total: 777,
          **reference_item.slice(
            :reference_price_amount,
            :reference_quantity,
            :reference_quantity_unit_code,
            :reference_price_tax_inclusion
          )
        },
        {
          pricing_source_kind: nil,
          price: 120,
          quantity: BigDecimal('1.5'),
          quantity_unit_code: 'liter',
          line_total: 778
        },
        {
          pricing_source_kind: 'count_unit_price',
          price: 120,
          quantity: 2,
          quantity_unit_code: 'each',
          line_total: 779
        },
        {
          pricing_source_kind: nil,
          price: 120,
          quantity: 2,
          quantity_unit_code: 'each',
          line_total: 780
        }
      ]

      result = aggregate(items, context: :edit_save)

      aggregate_failures do
        expect(result[:items].map { |item| item[:line_total] }).to eq([ 777, 778, 240, 240 ])
        expect(result[:total]).to eq(2_035)
      end
    end

    it 'unit kindではなくexplicit/count authority kindで金額sourceを選ぶ' do
      explicit_countable = {
        pricing_source_kind: 'explicit_line_total',
        price: 100,
        quantity: 2,
        quantity_unit_code: 'each',
        original_line_total: 777,
        line_total: 777
      }
      count_formula = {
        pricing_source_kind: 'count_unit_price',
        price: 100,
        quantity: 2,
        quantity_unit_code: 'each',
        quantity_unit_raw: nil,
        line_total: 777
      }

      result = aggregate([ explicit_countable, count_formula ], context: :edit_save)

      aggregate_failures do
        expect(result[:items].map { |item| item[:line_total] }).to eq([ 777, 200 ])
        expect(result[:total]).to eq(977)
      end
    end

    it 'count authorityをmeasurement unitやreference evidenceへ暗黙拡張しない' do
      invalid_items = [
        {
          pricing_source_kind: 'count_unit_price',
          price: 100,
          quantity: BigDecimal('1.5'),
          quantity_unit_code: 'liter',
          quantity_unit_raw: nil,
          line_total: 777
        },
        {
          pricing_source_kind: 'count_unit_price',
          price: 100,
          quantity: 2,
          quantity_unit_code: 'each',
          quantity_unit_raw: nil,
          reference_price_amount: 100,
          reference_quantity: 1,
          reference_quantity_unit_code: 'each',
          reference_price_tax_inclusion: 'gross'
        }
      ]

      invalid_items.each do |item|
        expect { aggregate([ item ], context: :edit_save) }.to raise_error(ArgumentError), item.inspect
      end
    end
  end

  describe 'current quantity unit amount contract' do
    countable_unit_codes = %w[each item piece bag sheet unit box set].freeze
    measurement_unit_codes = %w[gram kilogram milligram liter milliliter cubic_centimeter].freeze

    it '全countable単位ではmanual/edit_saveともpriceとquantityを正本にする' do
      aggregate_failures do
        %i[manual edit_save].product(countable_unit_codes).each do |context, code|
          explicit_result = aggregate(
            [ { price: 125, quantity: 2, quantity_unit_code: code, line_total: 777 } ],
            context: context
          )
          missing_result = aggregate(
            [ { price: 125, quantity: 2, quantity_unit_code: code, line_total: nil } ],
            context: context
          )

          [ explicit_result, missing_result ].each do |result|
            expect(result[:total]).to eq(250), "#{context}: #{code}"
            expect(result[:items].first[:original_line_total]).to eq(250), "#{context}: #{code}"
            expect(result[:items].first[:line_total]).to eq(250), "#{context}: #{code}"
          end
        end
      end
    end

    it '全measurement単位ではmanual/edit_saveとも明示line_totalを正本にし欠損時は0にする' do
      aggregate_failures do
        %i[manual edit_save].product(measurement_unit_codes).each do |context, code|
          explicit_result = aggregate(
            [ { price: 125, quantity: BigDecimal('2.500'), quantity_unit_code: code, line_total: 777 } ],
            context: context
          )
          missing_result = aggregate(
            [ { price: 125, quantity: BigDecimal('2.500'), quantity_unit_code: code, line_total: nil } ],
            context: context
          )

          expect(explicit_result[:total]).to eq(777), "#{context}: #{code}"
          expect(explicit_result[:items].first[:original_line_total]).to eq(777), "#{context}: #{code}"
          expect(explicit_result[:items].first[:line_total]).to eq(777), "#{context}: #{code}"
          expect(missing_result[:total]).to eq(0), "#{context}: #{code}"
          expect(missing_result[:items].first[:original_line_total]).to eq(0), "#{context}: #{code}"
          expect(missing_result[:items].first[:line_total]).to eq(0), "#{context}: #{code}"
        end
      end
    end
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

  it 'edit_saveで説明不能な保存済みcountable line_totalは明示priceとquantityから正規化する' do
    result = aggregate(
      [
        {
          price: 100,
          quantity: 2,
          quantity_unit_code: 'each',
          line_total: 200,
          amount_price_present: true,
          amount_quantity_present: true,
          amount_line_total_present: true,
          amount_countable_source_changed: false,
          amount_line_total_changed: true,
          amount_persisted_item: true,
          amount_persisted_original_line_total: nil,
          amount_persisted_line_total: 100
        }
      ],
      context: :edit_save
    )

    aggregate_failures do
      expect(result[:total]).to eq(200)
      expect(result[:items].first[:original_line_total]).to eq(200)
      expect(result[:items].first[:line_total]).to eq(200)
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
