require 'rails_helper'

RSpec.describe ReceiptQuantityUnit, type: :model do
  describe '.allowed_codes' do
    it '保存用の許可codeだけを返す' do
      expect(described_class.allowed_codes).to eq(
        %w[
          each
          item
          piece
          bag
          sheet
          unit
          box
          set
          gram
          kilogram
          milligram
          liter
          milliliter
          cubic_centimeter
        ]
      )
    end

    it 'catalog外の自由入力用codeを含めない' do
      expect(described_class.allowed_codes).not_to include('custom', 'other', 'freeform')
    end
  end

  describe '.countable_codes and .decimal_codes' do
    it '個数系と小数系を分離する' do
      aggregate_failures do
        expect(described_class.countable_codes).to contain_exactly(
          'each', 'item', 'piece', 'bag', 'sheet', 'unit', 'box', 'set'
        )
        expect(described_class.decimal_codes).to contain_exactly(
          'gram', 'kilogram', 'milligram', 'liter', 'milliliter', 'cubic_centimeter'
        )
      end
    end

    it '全14単位の入力契約をcodeごとに固定する' do
      expected_contracts = {
        'each' => [ :countable, '個', '1', 'numeric' ],
        'item' => [ :countable, '点', '1', 'numeric' ],
        'piece' => [ :countable, '本', '1', 'numeric' ],
        'bag' => [ :countable, '袋', '1', 'numeric' ],
        'sheet' => [ :countable, '枚', '1', 'numeric' ],
        'unit' => [ :countable, '台', '1', 'numeric' ],
        'box' => [ :countable, '箱', '1', 'numeric' ],
        'set' => [ :countable, 'セット', '1', 'numeric' ],
        'gram' => [ :decimal, 'g', '0.001', 'decimal' ],
        'kilogram' => [ :decimal, 'kg', '0.001', 'decimal' ],
        'milligram' => [ :decimal, 'mg', '0.001', 'decimal' ],
        'liter' => [ :decimal, 'L', '0.001', 'decimal' ],
        'milliliter' => [ :decimal, 'ml', '0.001', 'decimal' ],
        'cubic_centimeter' => [ :decimal, 'cc', '0.001', 'decimal' ]
      }

      aggregate_failures do
        expected_contracts.each do |code, (kind, label, step, inputmode)|
          expect(described_class.label(code, locale: :ja)).to eq(label), code
          expect(described_class.countable?(code)).to eq(kind == :countable), code
          expect(described_class.decimal?(code)).to eq(kind == :decimal), code
          expect(described_class.step_for(code)).to eq(step), code
          expect(described_class.inputmode_for(code)).to eq(inputmode), code
        end
      end
    end
  end

  describe '.unit_for' do
    let(:expected_metadata) do
      {
        'each' => [ :count, 'count:each', Rational(1), Rational(1) ],
        'item' => [ :count, 'count:item', Rational(1), Rational(1) ],
        'piece' => [ :count, 'count:piece', Rational(1), Rational(1) ],
        'bag' => [ :count, 'count:bag', Rational(1), Rational(1) ],
        'sheet' => [ :count, 'count:sheet', Rational(1), Rational(1) ],
        'unit' => [ :count, 'count:unit', Rational(1), Rational(1) ],
        'box' => [ :count, 'count:box', Rational(1), Rational(1) ],
        'set' => [ :count, 'count:set', Rational(1), Rational(1) ],
        'gram' => [ :mass, 'mass', Rational(1), Rational(1, 1_000) ],
        'kilogram' => [ :mass, 'mass', Rational(1_000), Rational(1, 1_000) ],
        'milligram' => [ :mass, 'mass', Rational(1, 1_000), Rational(1, 1_000) ],
        'liter' => [ :volume, 'volume', Rational(1_000), Rational(1, 1_000) ],
        'milliliter' => [ :volume, 'volume', Rational(1), Rational(1, 1_000) ],
        'cubic_centimeter' => [ :volume, 'volume', Rational(1), Rational(1, 1_000) ]
      }
    end

    it '全14単位にdimension・換算group・exact scale・入力粒度・pricing roleを持つ' do
      expect(expected_metadata.keys).to eq(described_class.allowed_codes)

      aggregate_failures do
        expected_metadata.each do |code, (dimension, conversion_group, exact_scale, input_granularity)|
          unit = described_class.unit_for(code)

          expect(unit.dimension).to eq(dimension), code
          expect(unit.conversion_group).to eq(conversion_group), code
          expect(unit.exact_scale).to eq(exact_scale), code
          expect(unit.exact_scale).to be_a(Rational), code
          expect(unit.input_granularity).to eq(input_granularity), code
          expect(unit.input_granularity).to be_a(Rational), code
          expect(unit.allowed_pricing_roles).to contain_exactly(:purchased, :reference), code
        end
      end
    end

    it '未知codeをdefault unitへfallbackしない' do
      aggregate_failures do
        expect(described_class.unit_for(nil)).to be_nil
        expect(described_class.unit_for('')).to be_nil
        expect(described_class.unit_for('unknown')).to be_nil
      end
    end

    it '公開metadataをdeep immutableにする' do
      unit = described_class.unit_for('kilogram')

      aggregate_failures do
        expect(unit).to be_frozen
        expect(unit.code).to be_frozen
        expect(unit.conversion_group).to be_frozen
        expect(unit.input_aliases).to be_frozen
        expect(unit.input_aliases).to all(be_frozen)
        expect(unit.allowed_pricing_roles).to be_frozen
        expect { unit.code << '-changed' }.to raise_error(FrozenError)
        expect { unit.conversion_group << '-changed' }.to raise_error(FrozenError)
        expect { unit.input_aliases << 'changed' }.to raise_error(FrozenError)
        expect { unit.input_aliases.first << 'changed' }.to raise_error(FrozenError)
        expect { unit.allowed_pricing_roles << :changed }.to raise_error(FrozenError)
      end
    end
  end

  describe '.resolve' do
    it 'canonical codeと国非依存symbol aliasをcanonical codeとして解決する' do
      aggregate_failures do
        expect(described_class.resolve(' kilogram ')).to have_attributes(
          status: :known, code: 'kilogram', raw: 'kilogram'
        )
        expect(described_class.resolve(' kg ')).to have_attributes(
          status: :known, code: 'kilogram', raw: 'kg'
        )
      end
    end

    it '国固有aliasをglobal catalogで解決しない' do
      aggregate_failures do
        expect(described_class.resolve('個')).to have_attributes(status: :unknown, code: nil, raw: '個')
        expect(described_class.resolve('グラム')).to have_attributes(status: :unknown, code: nil, raw: 'グラム')
        expect(described_class.resolve('リットル')).to have_attributes(status: :unknown, code: nil, raw: 'リットル')
      end
    end

    it '全catalog aliasをcanonical codeか国非依存symbolだけに限定する' do
      expect(described_class::UNITS.flat_map(&:input_aliases)).to contain_exactly(
        'g', 'kg', 'mg', 'L', 'l', 'ml', 'mL', 'cc'
      )
    end

    it 'blankとunknownをeachへfallbackせず区別する' do
      aggregate_failures do
        expect(described_class.resolve('  ')).to have_attributes(status: :blank, code: nil, raw: '')
        expect(described_class.resolve(nil)).to have_attributes(status: :blank, code: nil, raw: '')
        expect(described_class.resolve(' 束 ')).to have_attributes(status: :unknown, code: nil, raw: '束')
      end
    end

    it '許可codeを指す追加aliasだけを既知単位として解決する' do
      aggregate_failures do
        expect(described_class.resolve('缶', aliases: { '缶' => 'piece' })).to have_attributes(
          status: :known, code: 'piece', raw: '缶'
        )
        expect(described_class.resolve('束', aliases: { '束' => 'unsupported' })).to have_attributes(
          status: :unknown, code: nil, raw: '束'
        )
      end
    end

    it '結果とraw値をimmutableにする' do
      source = +' kg '
      resolution = described_class.resolve(source)

      aggregate_failures do
        expect(resolution).to be_frozen
        expect(resolution.raw).to be_frozen
        expect { resolution.raw << 'changed' }.to raise_error(FrozenError)
        expect(source).to eq(' kg ')
      end
    end

    it 'invalid encodingやcontrolを除去して既知単位へ昇格しない' do
      invalid = "kg\xFF".b.force_encoding(Encoding::UTF_8)

      aggregate_failures do
        [ "g\0", "kg\u0001", invalid ].each do |input|
          expect(described_class.resolve(input).known?).to be(false), input.inspect
        end
      end
    end

    it '64 bytesを超えるraw inputをboundedなunknownとしてfail closedにする' do
      inputs = [
        '杯' * 65,
        "kg#{' ' * 100}",
        "kg#{'x' * 100_000}"
      ]

      inputs.each do |input|
        resolution = described_class.resolve(input)

        aggregate_failures input.bytesize.to_s do
          expect(resolution.known?).to be(false)
          expect(resolution.raw).to be_valid_encoding
          expect(resolution.raw.bytesize).to be <= 64
        end
      end
    end
  end

  describe 'exact conversion contract' do
    it 'massとvolumeのexact比率を返す' do
      aggregate_failures do
        expect(described_class.exact_conversion_ratio(from: 'gram', to: 'milligram')).to eq(Rational(1_000))
        expect(described_class.exact_conversion_ratio(from: 'kilogram', to: 'gram')).to eq(Rational(1_000))
        expect(described_class.exact_conversion_ratio(from: 'liter', to: 'milliliter')).to eq(Rational(1_000))
        expect(described_class.exact_conversion_ratio(from: 'cubic_centimeter', to: 'milliliter')).to eq(Rational(1))
      end
    end

    it '同一dimension内をbinary Floatなしでexact変換する' do
      aggregate_failures do
        expect(described_class.convert_exact(1, from: 'gram', to: 'milligram')).to eq(Rational(1_000))
        expect(described_class.convert_exact(BigDecimal('1.25'), from: 'kilogram', to: 'gram')).to eq(Rational(1_250))
        expect(described_class.convert_exact(1, from: 'kilogram', to: 'gram')).to eq(Rational(1_000))
        expect(described_class.convert_exact(1, from: 'liter', to: 'milliliter')).to eq(Rational(1_000))
        expect(described_class.convert_exact(1, from: 'cubic_centimeter', to: 'milliliter')).to eq(Rational(1))
      end
    end

    it 'g・mg・ml・ccの往復変換で元のexact値を維持する' do
      vectors = [
        [ Rational(342), 'gram', 'kilogram' ],
        [ Rational(1_200), 'milligram', 'gram' ],
        [ Rational(1_500), 'milliliter', 'liter' ],
        [ Rational(250), 'cubic_centimeter', 'milliliter' ]
      ]

      aggregate_failures do
        vectors.each do |quantity, from, to|
          converted = described_class.convert_exact(quantity, from: from, to: to)
          round_trip = described_class.convert_exact(converted, from: to, to: from)

          expect(round_trip).to eq(quantity), "#{from} -> #{to} -> #{from}"
        end
      end
    end

    it 'countableは同一codeのidentity変換だけを許可する' do
      aggregate_failures do
        expect(described_class.convertible?(from: 'box', to: 'box')).to be(true)
        expect(described_class.convert_exact(Rational(2), from: 'box', to: 'box')).to eq(Rational(2))
        expect(described_class.convertible?(from: 'box', to: 'each')).to be(false)
        expect(described_class.convertible?(from: 'bag', to: 'item')).to be(false)
        expect(described_class.convertible?(from: 'set', to: 'piece')).to be(false)
      end
    end

    it 'countable cross-codeとcross-dimensionを明示的に拒否する' do
      aggregate_failures do
        expect {
          described_class.convert_exact(1, from: 'box', to: 'each')
        }.to raise_error(ReceiptQuantityUnit::IncompatibleConversionError)
        expect {
          described_class.convert_exact(1, from: 'gram', to: 'milliliter')
        }.to raise_error(ReceiptQuantityUnit::IncompatibleConversionError)
      end
    end

    it 'blankとunknown codeを明示的に拒否する' do
      aggregate_failures do
        expect {
          described_class.convert_exact(1, from: '', to: 'gram')
        }.to raise_error(ReceiptQuantityUnit::UnknownUnitError)
        expect {
          described_class.convert_exact(1, from: 'unknown', to: 'gram')
        }.to raise_error(ReceiptQuantityUnit::UnknownUnitError)
      end
    end

    it 'binary Float quantityをexact sourceとして受け付けない' do
      expect {
        described_class.convert_exact(0.1, from: 'gram', to: 'milligram')
      }.to raise_error(ReceiptQuantityUnit::InvalidExactQuantityError)
    end

    it 'non-finite BigDecimal quantityをexact sourceとして受け付けない' do
      aggregate_failures do
        [ BigDecimal('NaN'), BigDecimal('Infinity'), BigDecimal('-Infinity') ].each do |quantity|
          expect {
            described_class.convert_exact(quantity, from: 'gram', to: 'milligram')
          }.to raise_error(ReceiptQuantityUnit::InvalidExactQuantityError), quantity.to_s
        end
      end
    end

    it 'zero denominatorをdomain errorとして拒否する' do
      expect {
        described_class.convert_exact('1/0', from: 'gram', to: 'milligram')
      }.to raise_error(ReceiptQuantityUnit::InvalidExactQuantityError)
    end

    it 'source quantityとunit codeをmutationしない' do
      quantity = +'1.25'
      from = +'kilogram'
      to = +'gram'

      result = described_class.convert_exact(quantity, from: from, to: to)

      aggregate_failures do
        expect(result).to eq(Rational(1_250))
        expect(quantity).to eq('1.25')
        expect(from).to eq('kilogram')
        expect(to).to eq('gram')
      end
    end
  end

  describe '.normalize' do
    it '保存codeはそのまま返す' do
      expect(described_class.normalize('kilogram')).to eq('kilogram')
    end

    it '国固有aliasはglobal catalogで変換せずdefault codeへfallbackする' do
      aggregate_failures do
        expect(described_class.normalize('個')).to eq('each')
        expect(described_class.normalize('点')).to eq('each')
        expect(described_class.normalize('本')).to eq('each')
        expect(described_class.normalize('袋')).to eq('each')
        expect(described_class.normalize('枚')).to eq('each')
        expect(described_class.normalize('台')).to eq('each')
        expect(described_class.normalize('箱')).to eq('each')
        expect(described_class.normalize('セット')).to eq('each')
      end
    end

    it '計量単位ラベルを保存codeへ変換する' do
      aggregate_failures do
        expect(described_class.normalize('g')).to eq('gram')
        expect(described_class.normalize('kg')).to eq('kilogram')
        expect(described_class.normalize('mg')).to eq('milligram')
        expect(described_class.normalize('L')).to eq('liter')
        expect(described_class.normalize('ml')).to eq('milliliter')
        expect(described_class.normalize('cc')).to eq('cubic_centimeter')
      end
    end

    it '空値はdefault codeへ変換する' do
      aggregate_failures do
        expect(described_class.normalize(nil)).to eq('each')
        expect(described_class.normalize('')).to eq('each')
      end
    end

    it '候補外の未知単位は保持しない' do
      aggregate_failures do
        expect(described_class.normalize('通')).to eq('each')
        expect(described_class.normalize('束')).to eq('each')
        expect(described_class.normalize('杯')).to eq('each')
      end
    end

    it '国別profile aliasを受け取って正規化できる' do
      aliases = { '缶' => 'piece' }

      aggregate_failures do
        expect(described_class.normalize('缶', aliases: aliases)).to eq('piece')
        expect(described_class.normalize('個', aliases: aliases)).to eq('each')
        expect(described_class.normalize('通', aliases: aliases)).to eq('each')
      end
    end
  end

  describe '.label' do
    it 'ja localeでは日本語/記号ラベルを返す' do
      aggregate_failures do
        expect(described_class.label('each', locale: :ja)).to eq('個')
        expect(described_class.label('kilogram', locale: :ja)).to eq('kg')
      end
    end

    it 'en localeでは英語ラベルを返す' do
      aggregate_failures do
        expect(described_class.label('each', locale: :en)).to eq('each')
        expect(described_class.label('item', locale: :en)).to eq('item')
      end
    end
  end

  describe '.options' do
    it '表示ラベルと保存codeのpairを返す' do
      expect(described_class.options(locale: :ja)).to include([ '個', 'each' ], [ 'kg', 'kilogram' ])
    end
  end

  describe '.option_entries' do
    it 'data属性などへ渡しやすいvalue/label形式を返す' do
      expect(described_class.option_entries(locale: :ja)).to include(
        { value: 'each', label: '個' },
        { value: 'kilogram', label: 'kg' }
      )
    end
  end

  describe '.step_for and .inputmode_for' do
    it '個数系は整数入力、計量系は小数入力にする' do
      aggregate_failures do
        expect(described_class.step_for('each')).to eq('1')
        expect(described_class.inputmode_for('each')).to eq('numeric')
        expect(described_class.step_for('kilogram')).to eq('0.001')
        expect(described_class.inputmode_for('kilogram')).to eq('decimal')
      end
    end
  end
end
