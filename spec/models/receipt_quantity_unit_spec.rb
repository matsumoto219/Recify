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

    it 'custom/other/legacy自由入力用codeを含めない' do
      expect(described_class.allowed_codes).not_to include('custom', 'other', 'legacy')
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

  describe '.normalize' do
    it '保存codeはそのまま返す' do
      expect(described_class.normalize('kilogram')).to eq('kilogram')
    end

    it '旧日本語ラベルを保存codeへ変換する' do
      aggregate_failures do
        expect(described_class.normalize('個')).to eq('each')
        expect(described_class.normalize('点')).to eq('item')
        expect(described_class.normalize('本')).to eq('piece')
        expect(described_class.normalize('袋')).to eq('bag')
        expect(described_class.normalize('枚')).to eq('sheet')
        expect(described_class.normalize('台')).to eq('unit')
        expect(described_class.normalize('箱')).to eq('box')
        expect(described_class.normalize('セット')).to eq('set')
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
