require 'rails_helper'

RSpec.describe Amounts::ReferenceItemExtension do
  def calculate(**overrides)
    described_class.call(
      reference_price_amount: BigDecimal('120'),
      reference_quantity: BigDecimal('500'),
      reference_unit_code: 'milliliter',
      purchased_quantity: BigDecimal('1.5'),
      purchased_unit_code: 'liter',
      reference_price_tax_inclusion: :gross,
      **overrides
    )
  end

  describe '.call' do
    vectors = [
      {
        label: '120円/500ml × 1.5L',
        attributes: {
          reference_price_amount: BigDecimal('120'),
          reference_quantity: '500',
          reference_unit_code: 'milliliter',
          purchased_quantity: BigDecimal('1.5'),
          purchased_unit_code: 'liter'
        },
        exact_amount: Rational(360),
        projected_amount: 360
      },
      {
        label: '498円/100g × 342g',
        attributes: {
          reference_price_amount: '498',
          reference_quantity: Rational(100),
          reference_unit_code: 'gram',
          purchased_quantity: '342',
          purchased_unit_code: 'gram'
        },
        exact_amount: Rational(42_579, 25),
        projected_amount: 1_703
      },
      {
        label: '1480円/100g × 342g',
        attributes: {
          reference_price_amount: Rational(1_480),
          reference_quantity: BigDecimal('100'),
          reference_unit_code: 'gram',
          purchased_quantity: Rational(342),
          purchased_unit_code: 'gram'
        },
        exact_amount: Rational(25_308, 5),
        projected_amount: 5_062
      },
      {
        label: '105円/100g × 10g',
        attributes: {
          reference_price_amount: '105',
          reference_quantity: '100',
          reference_unit_code: 'gram',
          purchased_quantity: '10',
          purchased_unit_code: 'gram'
        },
        exact_amount: Rational(21, 2),
        projected_amount: 11
      },
      {
        label: '100円/3g × 1g',
        attributes: {
          reference_price_amount: '100',
          reference_quantity: '3',
          reference_unit_code: 'gram',
          purchased_quantity: '1',
          purchased_unit_code: 'gram'
        },
        exact_amount: Rational(100, 3),
        projected_amount: 33
      }
    ].freeze

    it 'exact sourceをRationalのまま計算しitem末尾でhalf-upを1回だけ適用する' do
      aggregate_failures do
        vectors.each do |vector|
          result = calculate(**vector.fetch(:attributes))

          expect(result).to have_attributes(
            exact_amount: vector.fetch(:exact_amount),
            projected_amount: vector.fetch(:projected_amount),
            reference_price_tax_inclusion: :gross
          ), vector.fetch(:label)
          expect(result.exact_amount).to be_a(Rational), vector.fetch(:label)
        end
      end
    end

    it 'half-up境界の直前と直後をexact rationalのまま判定する' do
      before_tie = calculate(
        reference_price_amount: '0.999998',
        reference_quantity: 2,
        reference_unit_code: 'gram',
        purchased_quantity: 1,
        purchased_unit_code: 'gram'
      )
      after_tie = calculate(
        reference_price_amount: '1.000002',
        reference_quantity: 2,
        reference_unit_code: 'gram',
        purchased_quantity: 1,
        purchased_unit_code: 'gram'
      )

      aggregate_failures do
        expect(before_tie.exact_amount).to eq(Rational(499_999, 1_000_000))
        expect(before_tie.projected_amount).to eq(0)
        expect(after_tie.exact_amount).to eq(Rational(500_001, 1_000_000))
        expect(after_tie.projected_amount).to eq(1)
      end
    end

    it '同じreference basisを比例拡大してもexact extensionを変えない' do
      base = calculate(
        reference_price_amount: 498,
        reference_quantity: 100,
        reference_unit_code: 'gram',
        purchased_quantity: 342,
        purchased_unit_code: 'gram'
      )
      scaled = calculate(
        reference_price_amount: 996,
        reference_quantity: 200,
        reference_unit_code: 'gram',
        purchased_quantity: 342,
        purchased_unit_code: 'gram'
      )

      expect(scaled).to have_attributes(
        exact_amount: base.exact_amount,
        projected_amount: base.projected_amount
      )
    end

    it 'gross/netを計算値とは分離した明示source metadataとして返す' do
      aggregate_failures do
        [ :gross, 'net' ].each do |tax_inclusion|
          result = calculate(reference_price_tax_inclusion: tax_inclusion)

          expect(result.reference_price_tax_inclusion).to eq(tax_inclusion.to_sym)
          expect(result.exact_amount).to eq(Rational(360))
          expect(result.projected_amount).to eq(360)
        end
      end
    end

    it '同じvolumeをL/ml/ccで表してもsource unitを変更せず同じexact amountを得る' do
      liter = calculate(purchased_quantity: '1.5', purchased_unit_code: 'liter')
      milliliter = calculate(purchased_quantity: '1500', purchased_unit_code: 'milliliter')
      cubic_centimeter = calculate(purchased_quantity: '1500', purchased_unit_code: 'cubic_centimeter')

      expect([ liter, milliliter, cubic_centimeter ].map(&:exact_amount)).to all(eq(Rational(360)))
    end

    it '同一countable codeのidentity conversionだけを許可する' do
      result = calculate(
        reference_price_amount: '100',
        reference_quantity: '10',
        reference_unit_code: 'each',
        purchased_quantity: '3',
        purchased_unit_code: 'each'
      )

      expect(result).to have_attributes(exact_amount: Rational(30), projected_amount: 30)
    end

    it '0円のreference priceをexact sourceとして許可する' do
      result = calculate(reference_price_amount: '0')

      expect(result).to have_attributes(exact_amount: Rational(0), projected_amount: 0)
    end

    it 'input hashとmutable Stringを変更せずimmutable resultを返す' do
      amount = +'120.0'
      reference_quantity = +'500'
      reference_unit = +'milliliter'
      purchased_quantity = +'1.5'
      purchased_unit = +'liter'
      tax_inclusion = +'gross'
      attributes = {
        reference_price_amount: amount,
        reference_quantity: reference_quantity,
        reference_unit_code: reference_unit,
        purchased_quantity: purchased_quantity,
        purchased_unit_code: purchased_unit,
        reference_price_tax_inclusion: tax_inclusion
      }
      original = attributes.transform_values(&:dup)

      result = described_class.call(**attributes)

      aggregate_failures do
        expect(attributes).to eq(original)
        expect([ amount, reference_quantity, reference_unit, purchased_quantity, purchased_unit, tax_inclusion ])
          .to all(satisfy { |value| !value.frozen? })
        expect(result).to be_frozen
        expect(result.exact_amount).to be_frozen
      end
    end
  end

  describe 'invalid source' do
    it 'cross-dimension、countable cross-code、alias、unknown/blank unitを拒否する' do
      invalid_units = [
        { reference_unit_code: 'gram', purchased_unit_code: 'liter' },
        { reference_unit_code: 'each', purchased_unit_code: 'box' },
        { reference_unit_code: 'ml' },
        { purchased_unit_code: 'L' },
        { reference_unit_code: :milliliter },
        { purchased_unit_code: :liter },
        { reference_unit_code: 'unknown' },
        { purchased_unit_code: '' }
      ]

      invalid_units.each do |attributes|
        expect { calculate(**attributes) }
          .to raise_error(Amounts::ItemQuantitySemantics::InvalidFormulaSourceError), attributes.inspect
      end
    end

    it 'nil・負数・Float・非数値・non-finite reference priceを拒否する' do
      invalid_amounts = [
        nil,
        -1,
        Rational(-1, 2),
        1.5,
        'not-a-number',
        BigDecimal('NaN'),
        BigDecimal('Infinity')
      ]

      invalid_amounts.each do |amount|
        expect { calculate(reference_price_amount: amount) }
          .to raise_error(described_class::InvalidSourceError), amount.inspect
      end
    end

    it 'invalid quantityとinput granularity違反をformula sourceにしない' do
      invalid_quantities = [ nil, '0', '-1', 1.5, '0.0001' ]

      invalid_quantities.each do |quantity|
        expect { calculate(purchased_quantity: quantity) }
          .to raise_error(Amounts::ItemQuantitySemantics::InvalidFormulaSourceError), quantity.inspect
      end
    end

    it 'gross/net以外や欠損したtax inclusionを推測しない' do
      [ nil, :unknown, 'included' ].each do |tax_inclusion|
        expect { calculate(reference_price_tax_inclusion: tax_inclusion) }
          .to raise_error(described_class::InvalidSourceError), tax_inclusion.inspect
      end
    end

    it 'discount・tax projection・printed totalをcomponentへ混ぜない' do
      aggregate_failures do
        expect { calculate(discount_amount: 10) }.to raise_error(ArgumentError)
        expect { calculate(tax_rate: BigDecimal('0.1')) }.to raise_error(ArgumentError)
        expect { calculate(line_total: 360) }.to raise_error(ArgumentError)
      end
    end
  end
end
