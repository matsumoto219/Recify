require 'rails_helper'

RSpec.describe ReceiptItem, type: :model do
  def build_item(**attributes)
    build(:receipt).receipt_items.build({
      confirmed_name: '計量価格契約商品',
      price: 240,
      quantity: BigDecimal('1'),
      quantity_unit_code: 'liter',
      line_total: 240,
      needs_review: false
    }.merge(attributes))
  end

  def canonical_reference_attributes(**overrides)
    {
      reference_price_amount: BigDecimal('120'),
      reference_quantity: BigDecimal('500'),
      reference_quantity_unit_code: 'milliliter',
      reference_quantity_unit_raw: nil
    }.merge(overrides)
  end

  def raw_reference_attributes(**overrides)
    {
      reference_price_amount: BigDecimal('120'),
      reference_quantity: BigDecimal('500'),
      reference_quantity_unit_code: nil,
      reference_quantity_unit_raw: 'fluid_ounce'
    }.merge(overrides)
  end

  describe 'legacy source metadata compatibility' do
    it '新しいsource metadataがすべてNULLの既存行を有効なまま維持する' do
      item = build_item(
        pricing_source_kind: nil,
        reference_price_amount: nil,
        reference_quantity: nil,
        reference_quantity_unit_code: nil,
        quantity_unit_raw: nil,
        reference_quantity_unit_raw: nil
      )

      expect(item).to be_valid
    end

    it '既存行を保存・再読込しても新しいsource metadataをNULLのまま維持する' do
      item = build_item

      item.save!
      item.reload

      expect(item.attributes.values_at(
        'pricing_source_kind',
        'reference_price_amount',
        'reference_quantity',
        'reference_quantity_unit_code',
        'quantity_unit_raw',
        'reference_quantity_unit_raw'
      )).to all(be_nil)
    end
  end

  describe 'pricing source kind integrity' do
    it '承認された3種類だけを許可し、review stateをauthority kindとして保存しない' do
      aggregate_failures do
        %w[count_unit_price explicit_line_total reference_quantity_price].each do |kind|
          item = case kind
          when 'count_unit_price'
            build_item(pricing_source_kind: kind, quantity_unit_code: 'each')
          when 'explicit_line_total'
            build_item(pricing_source_kind: kind)
          else
            build_item(pricing_source_kind: kind, **canonical_reference_attributes)
          end

          expect(item).to be_valid, kind
        end

        %w[ambiguous unsupported arbitrary].each do |kind|
          item = build_item(pricing_source_kind: kind)

          expect(item).not_to be_valid, kind
          expect(item.errors.of_kind?(:pricing_source_kind, :inclusion)).to be(true), kind
        end
      end
    end

    it 'count formulaは既存price・quantity・known countable unitを必要とする' do
      aggregate_failures do
        expect(build_item(pricing_source_kind: 'count_unit_price', quantity_unit_code: 'each')).to be_valid

        [
          build_item(pricing_source_kind: 'count_unit_price', price: nil, quantity_unit_code: 'each'),
          build_item(pricing_source_kind: 'count_unit_price', quantity: nil, quantity_unit_code: 'each'),
          build_item(pricing_source_kind: 'count_unit_price', quantity_unit_code: 'liter'),
          build_item(
            pricing_source_kind: 'count_unit_price',
            quantity_unit_code: 'each',
            **canonical_reference_attributes
          ),
          build_item(
            pricing_source_kind: 'count_unit_price',
            quantity_unit_code: 'each',
            quantity_unit_raw: 'bundle'
          )
        ].each do |item|
          expect(item).not_to be_valid
          expect(item.errors.of_kind?(:pricing_source_kind, :invalid)).to be(true)
        end
      end
    end

    it 'explicit totalは0円を含むnon-nil line_totalをauthorityとして要求する' do
      aggregate_failures do
        expect(build_item(pricing_source_kind: 'explicit_line_total', line_total: 0)).to be_valid

        missing = build_item(pricing_source_kind: 'explicit_line_total', line_total: nil)
        expect(missing).not_to be_valid
        expect(missing.errors.of_kind?(:pricing_source_kind, :invalid)).to be(true)
      end
    end

    it 'explicit totalではcompleteなcanonical/raw診断evidenceとunknown purchased rawを保持できる' do
      aggregate_failures do
        expect(
          build_item(pricing_source_kind: 'explicit_line_total', **canonical_reference_attributes)
        ).to be_valid
        expect(
          build_item(pricing_source_kind: 'explicit_line_total', **raw_reference_attributes)
        ).to be_valid
        expect(
          build_item(pricing_source_kind: 'explicit_line_total', quantity_unit_raw: 'bundle')
        ).to be_valid
      end
    end

    it 'reference formulaはcanonical complete tupleとcompatibleなpurchased quantity/unitを要求する' do
      valid = build_item(
        pricing_source_kind: 'reference_quantity_price',
        price: nil,
        quantity: BigDecimal('1.5'),
        quantity_unit_code: 'liter',
        **canonical_reference_attributes
      )
      incompatible = build_item(
        pricing_source_kind: 'reference_quantity_price',
        quantity_unit_code: 'kilogram',
        **canonical_reference_attributes
      )
      unknown_reference = build_item(
        pricing_source_kind: 'reference_quantity_price',
        **raw_reference_attributes
      )

      aggregate_failures do
        expect(valid).to be_valid
        expect(valid.price).to be_nil

        [
          build_item(
            pricing_source_kind: 'reference_quantity_price',
            quantity: nil,
            **canonical_reference_attributes
          ),
          incompatible,
          unknown_reference,
          build_item(
            pricing_source_kind: 'reference_quantity_price',
            quantity_unit_raw: 'bundle',
            **canonical_reference_attributes
          )
        ].each do |item|
          expect(item).not_to be_valid
          expect(item.errors.of_kind?(:pricing_source_kind, :invalid)).to be(true)
        end
      end
    end
  end

  describe 'exact reference numeric bounds' do
    source_vectors = [
      [ '1.8', '1', 'gram', 'gram' ],
      [ '0.9', '1', 'milligram', 'milligram' ],
      [ '498', '100', 'gram', 'gram' ],
      [ '120', '500', 'milliliter', 'liter' ],
      [ '140', '10', 'liter', 'liter' ]
    ].freeze

    it '承認された小数source vectorをBigDecimalのまま損失なく保持する' do
      aggregate_failures do
        source_vectors.each do |amount, reference_quantity, reference_unit, purchased_unit|
          item = build_item(
            pricing_source_kind: 'reference_quantity_price',
            price: nil,
            quantity_unit_code: purchased_unit,
            reference_price_amount: BigDecimal(amount),
            reference_quantity: BigDecimal(reference_quantity),
            reference_quantity_unit_code: reference_unit
          )

          expect(item).to be_valid, "#{amount}円 / #{reference_quantity} #{reference_unit}"
          expect(item.reference_price_amount).to eq(BigDecimal(amount))
          expect(item.reference_quantity).to eq(BigDecimal(reference_quantity))
        end
      end
    end

    it '承認vectorと境界値を保存・再読込してもexact decimal sourceを維持する' do
      persisted_vectors = source_vectors + [
        [ '0', '0.001', 'gram', 'gram' ],
        [ '999999999998.999999', '9999.999', 'liter', 'liter' ],
        [ '999999999999', '1', 'liter', 'liter' ]
      ]

      aggregate_failures do
        persisted_vectors.each do |amount, reference_quantity, reference_unit, purchased_unit|
          item = build_item(
            pricing_source_kind: 'reference_quantity_price',
            price: nil,
            quantity_unit_code: purchased_unit,
            reference_price_amount: amount,
            reference_quantity: reference_quantity,
            reference_quantity_unit_code: reference_unit
          )

          item.save!
          item.reload

          expect(item.reference_price_amount).to eq(BigDecimal(amount))
          expect(item.reference_quantity).to eq(BigDecimal(reference_quantity))
          expect(item.pricing_source_kind).to eq('reference_quantity_price')
          expect(item.reference_quantity_unit_code).to eq(reference_unit)
        end
      end
    end

    it 'reference amountは0から999999999999、最大6桁の小数を許可する' do
      aggregate_failures do
        [
          BigDecimal('0'),
          BigDecimal('0.000001'),
          BigDecimal('999999999998.999999'),
          BigDecimal('999999999999')
        ].each do |amount|
          item = build_item(
            pricing_source_kind: 'reference_quantity_price',
            **canonical_reference_attributes(reference_price_amount: amount)
          )

          expect(item).to be_valid, amount.to_s('F')
        end
      end
    end

    it 'reference amountの負数・上限超過・7桁小数・非finite・非exact入力を拒否する' do
      invalid_values = [
        BigDecimal('-0.000001'),
        BigDecimal('999999999999.000001'),
        BigDecimal('1.1234567'),
        BigDecimal('NaN'),
        BigDecimal('Infinity'),
        Rational(1, 3),
        'not-a-number'
      ]

      aggregate_failures do
        invalid_values.each do |amount|
          item = build_item(
            pricing_source_kind: 'reference_quantity_price',
            **canonical_reference_attributes(reference_price_amount: amount)
          )

          expect(item).not_to be_valid, amount.inspect
          expect(item.errors.of_kind?(:reference_price_amount, :invalid)).to be(true), amount.inspect
        end
      end
    end

    it 'Stringのreference amountもcast前のexact値で上限とscaleを検証する' do
      aggregate_failures do
        %w[1.8 0.9 999999999998.999999 999999999999].each do |amount|
          item = build_item(
            pricing_source_kind: 'reference_quantity_price',
            **canonical_reference_attributes(reference_price_amount: amount)
          )

          expect(item).to be_valid, amount
        end

        %w[999999999999.000001 1000000000000 1.1234567].each do |amount|
          item = build_item(
            pricing_source_kind: 'reference_quantity_price',
            **canonical_reference_attributes(reference_price_amount: amount)
          )

          expect(item).not_to be_valid, amount
          expect(item.errors.of_kind?(:reference_price_amount, :invalid)).to be(true), amount
        end
      end
    end

    it 'reference quantityは0より大きく9999.999以下、最大3桁の小数を許可する' do
      aggregate_failures do
        [ BigDecimal('0.001'), BigDecimal('1'), BigDecimal('9999.999') ].each do |quantity|
          item = build_item(
            pricing_source_kind: 'reference_quantity_price',
            reference_price_amount: BigDecimal('1'),
            reference_quantity: quantity,
            reference_quantity_unit_code: 'milliliter'
          )

          expect(item).to be_valid, quantity.to_s('F')
        end
      end
    end

    it 'reference quantityの0・負数・上限超過・4桁小数・非finiteを拒否する' do
      invalid_values = [
        BigDecimal('0'),
        BigDecimal('-0.001'),
        BigDecimal('10000'),
        BigDecimal('1.0001'),
        BigDecimal('NaN'),
        BigDecimal('Infinity')
      ]

      aggregate_failures do
        invalid_values.each do |quantity|
          item = build_item(
            pricing_source_kind: 'reference_quantity_price',
            reference_price_amount: BigDecimal('1'),
            reference_quantity: quantity,
            reference_quantity_unit_code: 'milliliter'
          )

          expect(item).not_to be_valid, quantity.inspect
          expect(item.errors.of_kind?(:reference_quantity, :invalid)).to be(true), quantity.inspect
        end
      end
    end

    it 'Stringのreference quantityもcast前のexact値で上限とscaleを検証する' do
      aggregate_failures do
        %w[0.001 1 500 9999.999].each do |quantity|
          item = build_item(
            pricing_source_kind: 'reference_quantity_price',
            reference_price_amount: '1.8',
            reference_quantity: quantity,
            reference_quantity_unit_code: 'liter'
          )

          expect(item).to be_valid, quantity
        end

        %w[0 10000 1.0001].each do |quantity|
          item = build_item(
            pricing_source_kind: 'reference_quantity_price',
            reference_price_amount: '1.8',
            reference_quantity: quantity,
            reference_quantity_unit_code: 'liter'
          )

          expect(item).not_to be_valid, quantity
          expect(item.errors.of_kind?(:reference_quantity, :invalid)).to be(true), quantity
        end
      end
    end

    it 'countable reference unitではinput granularityに合わない小数quantityを拒否する' do
      item = build_item(
        pricing_source_kind: nil,
        reference_price_amount: BigDecimal('10'),
        reference_quantity: BigDecimal('1.5'),
        reference_quantity_unit_code: 'each'
      )

      aggregate_failures do
        expect(item).not_to be_valid
        expect(item.errors.of_kind?(:reference_quantity, :invalid)).to be(true)
      end
    end

    it 'unconstrained numeric sourceの小数桁をDB castで丸める前に検証する' do
      amount = BigDecimal('123.1234567')
      quantity = BigDecimal('1.0001')
      item = build_item(
        pricing_source_kind: 'reference_quantity_price',
        reference_price_amount: amount,
        reference_quantity: quantity,
        reference_quantity_unit_code: 'liter'
      )

      aggregate_failures do
        expect(item.reference_price_amount_before_type_cast).to eq(amount)
        expect(item.reference_quantity_before_type_cast).to eq(quantity)
        expect(item).not_to be_valid
        expect(item.errors.of_kind?(:reference_price_amount, :invalid)).to be(true)
        expect(item.errors.of_kind?(:reference_quantity, :invalid)).to be(true)
      end
    end
  end

  describe 'reference evidence shape' do
    it 'reference evidenceは全fieldなし・complete canonical・complete rawの3状態だけを許可する' do
      valid_items = [
        build_item(pricing_source_kind: nil),
        build_item(pricing_source_kind: nil, **canonical_reference_attributes),
        build_item(pricing_source_kind: nil, **raw_reference_attributes)
      ]
      partial_items = [
        build_item(pricing_source_kind: nil, reference_price_amount: BigDecimal('120')),
        build_item(
          pricing_source_kind: nil,
          reference_price_amount: BigDecimal('120'),
          reference_quantity: BigDecimal('500')
        ),
        build_item(
          pricing_source_kind: nil,
          reference_price_amount: BigDecimal('120'),
          reference_quantity: BigDecimal('500'),
          reference_quantity_unit_code: 'milliliter',
          reference_quantity_unit_raw: 'fluid_ounce'
        )
      ]

      aggregate_failures do
        valid_items.each { |item| expect(item).to be_valid }
        partial_items.each do |item|
          expect(item).not_to be_valid
          expect(item.errors.of_kind?(:reference_price_amount, :invalid)).to be(true)
        end
      end
    end

    it 'canonical reference unitは現行catalogのcanonical codeだけを許可する' do
      aggregate_failures do
        expect(build_item(pricing_source_kind: nil, **canonical_reference_attributes)).to be_valid

        %w[ml unknown].each do |code|
          item = build_item(
            pricing_source_kind: nil,
            **canonical_reference_attributes(reference_quantity_unit_code: code)
          )

          expect(item).not_to be_valid, code
          expect(item.errors.of_kind?(:reference_quantity_unit_code, :inclusion)).to be(true), code
        end
      end
    end
  end

  describe 'raw unit evidence' do
    it 'trim済み1..64文字でcontrol文字を含まないraw tokenだけを許可する' do
      valid = build_item(pricing_source_kind: nil, quantity_unit_raw: 'fluid_ounce')
      invalid_values = [
        '',
        ' fluid_ounce',
        "fluid\nounce",
        'x' * 65
      ]

      aggregate_failures do
        expect(valid).to be_valid
        invalid_values.each do |raw|
          item = build_item(pricing_source_kind: nil, quantity_unit_raw: raw)

          expect(item).not_to be_valid, raw.inspect
          expect(item.errors.of_kind?(:quantity_unit_raw, :invalid)).to be(true), raw.inspect
        end
      end
    end

    it 'reference raw tokenでも空白、control、上限超過を拒否する' do
      aggregate_failures do
        expect(build_item(pricing_source_kind: nil, **raw_reference_attributes)).to be_valid

        [ '', ' fluid_ounce', "fluid\u0000ounce", 'x' * 65 ].each do |raw|
          item = build_item(
            pricing_source_kind: nil,
            **raw_reference_attributes(reference_quantity_unit_raw: raw)
          )

          expect(item).not_to be_valid, raw.inspect
          expect(item.errors.of_kind?(:reference_quantity_unit_raw, :invalid)).to be(true), raw.inspect
        end
      end
    end

    it 'catalogで既知になったsource表記もhistorical raw evidenceとして保持できる' do
      aggregate_failures do
        purchased = build_item(pricing_source_kind: nil, quantity_unit_raw: 'each')
        reference = build_item(
          pricing_source_kind: nil,
          **raw_reference_attributes(reference_quantity_unit_raw: 'ml')
        )

        expect(purchased).to be_valid
        expect(reference).to be_valid

        purchased.save!
        reference.save!

        expect(purchased.reload.quantity_unit_raw).to eq('each')
        expect(reference.reload.reference_quantity_unit_raw).to eq('ml')
      end
    end

    it 'unknown purchased rawは既存each projectionと共存してもformula authorityへ昇格しない' do
      item = build_item(
        pricing_source_kind: nil,
        quantity_unit_code: 'each',
        quantity_unit_raw: 'fluid_ounce'
      )

      aggregate_failures do
        expect(item).to be_valid
        expect(item.quantity_unit_code).to eq('each')
        expect(item.quantity_unit_raw).to eq('fluid_ounce')
        expect(item.pricing_source_kind).to be_nil
      end
    end

    it 'unknown reference rawをeachへ変換せずauthority-free evidenceとして保持する' do
      item = build_item(pricing_source_kind: nil, **raw_reference_attributes)

      aggregate_failures do
        expect(item).to be_valid
        expect(item.reference_quantity_unit_code).to be_nil
        expect(item.reference_quantity_unit_raw).to eq('fluid_ounce')
        expect(item.pricing_source_kind).to be_nil
      end
    end
  end
end
