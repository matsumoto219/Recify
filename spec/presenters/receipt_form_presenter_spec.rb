require 'rails_helper'

RSpec.describe ReceiptFormPresenter do
  it '購入入力変更状態をJSへ渡す' do
    presenter = described_class.new(
      receipt: build(:receipt),
      purchase_inputs_changed: true,
      adjustment_tax_detail_evidence_stale: true
    )

    aggregate_failures do
      expect(presenter.purchase_inputs_changed?).to be(true)
      expect(presenter.adjustment_tax_detail_evidence_stale?).to be(true)
    end
  end

  it 'invalid item sourceの422だけをフォームの復旧表示へ渡す' do
    aggregate_failures do
      expect(described_class.new(receipt: build(:receipt), invalid_item_source: true).invalid_item_source?).to be(true)
      expect(described_class.new(receipt: build(:receipt)).invalid_item_source?).to be(false)
    end
  end

  it 'adjustment分類のserver契約をJSへ渡す' do
    presenter = described_class.new(receipt: build(:receipt))

    aggregate_failures do
      expect(presenter.adjustment_purchase_kinds_value.split(',')).to contain_exactly(
        'service_charge',
        'late_night_charge',
        'delivery_fee',
        'bag_fee',
        'handling_fee',
        'coupon',
        'return_refund'
      )
      expect('キャッシュレス還元').to match(Regexp.new(presenter.adjustment_payment_label_pattern_value, Regexp::IGNORECASE))
      expect('payment discount').to match(Regexp.new(presenter.adjustment_payment_label_pattern_value, Regexp::IGNORECASE))
    end
  end

  it 'exact reference計算用の単位metadataをRuby catalogから有理数のまま渡す' do
    contract = described_class.new(receipt: build(:receipt)).reference_pricing_contract_value

    aggregate_failures do
      expect(contract.keys).to contain_exactly(
        'price_amount_max', 'price_amount_max_scale', 'quantity_max', 'quantity_max_scale', 'units'
      )
      expect(contract.fetch('units').keys).to eq(ReceiptQuantityUnit.allowed_codes)
      expect(contract.fetch('units')).to eq(
        ReceiptQuantityUnit.allowed_codes.to_h do |code|
          unit = ReceiptQuantityUnit.unit_for(code)
          [
            code,
            {
              'conversion_group' => unit.conversion_group,
              'scale_numerator' => unit.exact_scale.numerator.to_s,
              'scale_denominator' => unit.exact_scale.denominator.to_s,
              'granularity_numerator' => unit.input_granularity.numerator.to_s,
              'granularity_denominator' => unit.input_granularity.denominator.to_s,
              'allowed_pricing_roles' => unit.allowed_pricing_roles.map(&:to_s)
            }
          ]
        end
      )
      expect(contract.dig('units', 'each', 'conversion_group')).to eq('count:each')
      expect(contract.dig('units', 'liter', 'scale_numerator')).to eq('1000')
      expect(contract.dig('units', 'milligram', 'scale_denominator')).to eq('1000')
    end
  end

  describe '#adjustment_tax_detail_rates_value' do
    it '金額を持つ保存済みtax detailの税率だけをpercentageで渡し、不明rateも保持する' do
      receipt = create(:receipt)
      receipt.receipt_tax_details.create!(rate: BigDecimal('0.1'), net_amount: 100, amount: 10)
      receipt.receipt_tax_details.create!(rate: BigDecimal('0.08'), net_amount: 0, amount: 0)
      receipt.receipt_tax_details.create!(rate: nil, net_amount: 50, amount: 0)

      expect(described_class.new(receipt: receipt).adjustment_tax_detail_rates_value).to eq([ '10', nil ])
    end
  end

  describe '#reference_projection_fallback_tax_rate_value' do
    it 'Amount facadeが確定した単一税率をpercentage文字列で渡す' do
      receipt = create(:receipt, tax_rate: BigDecimal('0.08'))
      receipt.receipt_tax_details.create!(
        rate: BigDecimal('0.10'),
        net_amount: 100,
        amount: 10,
        description: '外税10%'
      )

      expect(described_class.new(receipt: receipt).reference_projection_fallback_tax_rate_value).to eq('10')
    end

    it '明示0%を空欄と区別し、根拠がなければ空文字を返す' do
      explicit_zero = build(:receipt, tax_rate: BigDecimal('0'))
      unknown = build(:receipt, tax_rate: nil)

      aggregate_failures do
        expect(described_class.new(receipt: explicit_zero).reference_projection_fallback_tax_rate_value).to eq('0')
        expect(described_class.new(receipt: unknown).reference_projection_fallback_tax_rate_value).to eq('')
      end
    end
  end

  describe '調整なし確認' do
    it 'receipt-level reasonがあり保存済み調整行がない編集画面だけで表示する' do
      receipt = create(:receipt, status: 'review_needed', review_reasons: [ 'adjustment_uncertain' ])

      presenter = described_class.new(receipt: receipt, adjustment_absence_confirmed: true)

      aggregate_failures do
        expect(presenter.adjustment_absence_confirmation_available?).to be(true)
        expect(presenter.adjustment_absence_confirmation_visible?).to be(true)
        expect(presenter.adjustment_absence_confirmed?).to be(true)
      end
    end

    it '新規調整行の422再表示中はpanelを残して非表示・未確認にする' do
      receipt = create(:receipt, status: 'review_needed', review_reasons: [ 'adjustment_uncertain' ])
      presenter = described_class.new(
        receipt: receipt,
        adjustment_absence_confirmed: true,
        submitted_params: {
          receipt_adjustments_attributes: {
            '0' => { kind: 'coupon', label: '入力中クーポン', amount: '10', sign: 'discount' }
          }
        }
      )

      aggregate_failures do
        expect(presenter.adjustment_absence_confirmation_available?).to be(true)
        expect(presenter.adjustment_absence_confirmation_visible?).to be(false)
        expect(presenter.adjustment_absence_confirmed?).to be(false)
      end
    end

    it 'reasonがない場合・新規作成・保存済み調整行がある場合は表示しない' do
      no_reason = create(:receipt, status: 'completed', review_reasons: [])
      new_receipt = build(:receipt, status: 'review_needed', review_reasons: [ 'adjustment_uncertain' ])
      with_adjustment = create(:receipt, status: 'review_needed', review_reasons: [ 'adjustment_uncertain' ])
      create(:receipt_adjustment, receipt: with_adjustment)

      aggregate_failures do
        expect(described_class.new(receipt: no_reason).adjustment_absence_confirmation_available?).to be(false)
        expect(described_class.new(receipt: new_receipt).adjustment_absence_confirmation_available?).to be(false)
        expect(described_class.new(receipt: with_adjustment).adjustment_absence_confirmation_available?).to be(false)
      end
    end
  end

  describe 'submitted form values' do
    it '保存失敗後のtop-level値と新規child行を表示専用に再構築する' do
      receipt = build(:receipt, memo: '保存済みメモ')
      presenter = described_class.new(
        receipt: receipt,
        submitted_params: {
          memo: '入力中メモ',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '入力中商品', quantity: '2', quantity_unit_code: 'each', price: '1e2'
            }
          },
          receipt_adjustments_attributes: {
            '0' => { kind: 'delivery_fee', label: '入力中送料', amount: '12abc', sign: 'surcharge' }
          },
          receipt_payments_attributes: {
            '0' => { method: '現金', amount: '1e2' }
          }
        }
      )

      item = presenter.visible_receipt_items.first
      adjustment = presenter.visible_receipt_adjustments.first
      payment = presenter.visible_receipt_payments.first
      item_row = presenter.item_row(item, new_record: true)
      adjustment_row = presenter.adjustment_row(adjustment, new_record: true)
      payment_row = presenter.payment_row(payment, new_record: true)

      aggregate_failures do
        expect(presenter.submitted_value(:memo, fallback: receipt.memo)).to eq('入力中メモ')
        expect(item_row.item_name).to eq('入力中商品')
        expect(item_row.quantity_value).to eq('2')
        expect(item_row.price_value).to eq('1e2')
        expect(adjustment_row.label_value).to eq('入力中送料')
        expect(adjustment_row.amount_value).to eq('12abc')
        expect(payment_row.method_value).to eq('現金')
        expect(payment_row.amount_value).to eq('1e2')
      end
    end

    it '保存失敗後の複数新規reference行へsubmitted authorityを対応付けて重複なく再構築する' do
      receipt = build(:receipt)
      normalized_items = [
        [ '基準価格商品A', '1.0', '1000.0', '1000.5' ],
        [ '基準価格商品B', '2.0', '2000.0', '2000.5' ],
        [ '基準価格商品C', '3.0', '3000.0', '3000.5' ]
      ].map do |name, quantity, price, reference_quantity|
        receipt.receipt_items.build(
          confirmed_name: name,
          quantity: BigDecimal(quantity),
          quantity_unit_code: 'liter',
          pricing_source_kind: 'reference_quantity_price',
          reference_price_amount: BigDecimal(price),
          reference_quantity: BigDecimal(reference_quantity),
          reference_quantity_unit_code: 'milliliter',
          reference_price_tax_inclusion: 'gross'
        )
      end
      submitted_rows = normalized_items.each_with_index.to_h do |item, index|
        [
          index.to_s,
          {
            confirmed_name: item.confirmed_name,
            quantity: "#{index + 1}.0",
            quantity_unit_code: 'liter',
            pricing_source_kind: 'reference_quantity_price',
            reference_price_amount: "#{index + 1}000.0",
            reference_quantity: "#{index + 1}000.5",
            reference_quantity_unit_code: 'milliliter',
            reference_price_tax_inclusion: 'gross'
          }
        ]
      end
      presenter = described_class.new(
        receipt: receipt,
        submitted_params: { receipt_items_attributes: submitted_rows }
      )

      visible_items = presenter.visible_receipt_items
      rows = visible_items.map { |item| presenter.item_row(item, new_record: true) }

      aggregate_failures do
        expect(visible_items).to eq(normalized_items)
        expect(visible_items.size).to eq(3)
        expect(rows.map(&:pricing_source_kind_value)).to eq([ 'reference_quantity_price' ] * 3)
        expect(rows.map(&:quantity_value)).to eq(%w[1.0 2.0 3.0])
        expect(rows.map(&:reference_price_amount_value)).to eq(%w[1000.0 2000.0 3000.0])
        expect(rows.map(&:reference_quantity_value)).to eq(%w[1000.5 2000.5 3000.5])
        expect(rows.map(&:reference_price_tax_inclusion_value)).to eq([ 'gross' ] * 3)
      end
    end

    it 'prune済みの新規item行をassociated rowへ同じ順序で対応し重複しない' do
      receipt = build(:receipt)
      normalized_items = [
        receipt.receipt_items.build(
          confirmed_name: '基準価格商品A',
          quantity: BigDecimal('1'),
          quantity_unit_code: 'liter',
          pricing_source_kind: 'reference_quantity_price',
          reference_price_amount: BigDecimal('100'),
          reference_quantity: BigDecimal('500'),
          reference_quantity_unit_code: 'milliliter',
          reference_price_tax_inclusion: 'gross'
        ),
        receipt.receipt_items.build(
          confirmed_name: '基準価格商品C',
          quantity: BigDecimal('3'),
          quantity_unit_code: 'liter',
          pricing_source_kind: 'reference_quantity_price',
          reference_price_amount: BigDecimal('300'),
          reference_quantity: BigDecimal('750'),
          reference_quantity_unit_code: 'milliliter',
          reference_price_tax_inclusion: 'gross'
        )
      ]
      presenter = described_class.new(
        receipt: receipt,
        submitted_params: {
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '基準価格商品A',
              quantity: '1.00',
              quantity_unit_code: 'liter',
              pricing_source_kind: 'reference_quantity_price',
              reference_price_amount: '100.00',
              reference_quantity: '500.00',
              reference_quantity_unit_code: 'milliliter',
              reference_price_tax_inclusion: 'gross'
            },
            '2' => {
              confirmed_name: '基準価格商品C',
              quantity: '3.00',
              quantity_unit_code: 'liter',
              pricing_source_kind: 'reference_quantity_price',
              reference_price_amount: '300.00',
              reference_quantity: '750.00',
              reference_quantity_unit_code: 'milliliter',
              reference_price_tax_inclusion: 'gross'
            }
          }
        }
      )

      visible_items = presenter.visible_receipt_items
      rows = visible_items.map { |item| presenter.item_row(item, new_record: true) }

      aggregate_failures do
        expect(visible_items).to eq(normalized_items)
        expect(rows.map(&:item_name)).to eq([ '基準価格商品A', '基準価格商品C' ])
        expect(rows.map(&:quantity_value)).to eq(%w[1.00 3.00])
        expect(rows.map(&:reference_price_amount_value)).to eq(%w[100.00 300.00])
        expect(rows.map(&:reference_quantity_value)).to eq(%w[500.00 750.00])
      end
    end

    it '保存済み行はindexではなくidでsubmitted valueを対応する' do
      receipt = create(:receipt)
      item_a = receipt.receipt_items.create!(
        confirmed_name: '保存済み商品A', quantity: 1, quantity_unit_code: 'each', line_total: 100
      )
      item_c = receipt.receipt_items.create!(
        confirmed_name: '保存済み商品C', quantity: 1, quantity_unit_code: 'each', line_total: 300
      )
      presenter = described_class.new(
        receipt: receipt,
        submitted_params: {
          receipt_items_attributes: {
            '8' => { id: item_c.id, tax_rate: '10.55' },
            '9' => { id: item_a.id, tax_rate: '8.25' }
          }
        }
      )

      aggregate_failures do
        expect(presenter.item_row(item_a, new_record: false).tax_rate_percentage_value).to eq('8.25')
        expect(presenter.item_row(item_c, new_record: false).tax_rate_percentage_value).to eq('10.55')
      end
    end

    it '保存失敗後のassociated new adjustment/paymentへsubmitted rowを対応し重複しない' do
      receipt = build(:receipt)
      adjustment = receipt.receipt_adjustments.build(
        kind: 'delivery_fee', label: '配送料', amount: 550, sign: 'surcharge', source: 'manual'
      )
      payment = receipt.receipt_payments.build(method: '現金', amount: 550)
      presenter = described_class.new(
        receipt: receipt,
        submitted_params: {
          receipt_adjustments_attributes: {
            '0' => { kind: 'delivery_fee', label: '配送料', amount: '550.00', sign: 'surcharge' }
          },
          receipt_payments_attributes: {
            '0' => { method: '現金', amount: '550.00' }
          }
        }
      )

      visible_adjustments = presenter.visible_receipt_adjustments
      visible_payments = presenter.visible_receipt_payments

      aggregate_failures do
        expect(visible_adjustments).to eq([ adjustment ])
        expect(visible_payments).to eq([ payment ])
        expect(presenter.adjustment_row(adjustment, new_record: true).amount_value).to eq('550.00')
        expect(presenter.payment_row(payment, new_record: true).amount_value).to eq('550.00')
      end
    end

    it '保存済み明細の削除操作を422再表示用のhidden行として保持する' do
      receipt = create(:receipt)
      visible_item = receipt.receipt_items.create!(
        confirmed_name: '表示する商品',
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 100
      )
      destroyed_item = receipt.receipt_items.create!(
        confirmed_name: '削除中の商品',
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 200
      )
      presenter = described_class.new(
        receipt: receipt,
        submitted_params: {
          receipt_items_attributes: {
            '0' => { id: visible_item.id, _destroy: '0' },
            '1' => { id: destroyed_item.id, _destroy: '1' }
          }
        }
      )

      aggregate_failures do
        expect(presenter.visible_receipt_items).to contain_exactly(visible_item)
        expect(presenter.destroyed_receipt_items).to contain_exactly(destroyed_item)
      end
    end

    it '1万件相当の422再表示でもsubmitted child rowsをcollectionごとに1回だけ列挙する' do
      item_class = Struct.new(:id) do
        def persisted? = true
        def marked_for_destruction? = false
      end
      items = Array.new(10_000) { |index| item_class.new(index + 1) }
      rows = Array.new(9_999) do |index|
        { id: items[index].id, _destroy: (index == 5_000) ? '1' : '0' }
      end
      rows << { confirmed_name: '422で再表示する新規商品', quantity_unit_code: 'each' }

      submitted_collection = Object.new
      submitted_collection.define_singleton_method(:enumeration_count) { @enumeration_count.to_i }
      submitted_collection.define_singleton_method(:each_value) do |&block|
        @enumeration_count = enumeration_count + 1
        raise 'submitted rows were enumerated more than once' if enumeration_count > 1

        rows.each(&block)
      end
      receipt = instance_double(Receipt, receipt_items: items)
      presenter = described_class.new(
        receipt: receipt,
        submitted_params: { receipt_items_attributes: submitted_collection }
      )

      visible = presenter.visible_receipt_items
      destroyed = presenter.destroyed_receipt_items
      presenter.item_row(items.last, new_record: false)

      aggregate_failures do
        expect(visible.size).to eq(10_000)
        expect(destroyed).to eq([ items[5_000] ])
        expect(submitted_collection.enumeration_count).to eq(1)
      end
    end
  end

  describe '#error_flags' do
    it 'maps receipt review reasons to field flags' do
      receipt = build(
        :receipt,
        review_reasons: %w[store_name_missing payment_method_uncertain purchased_at_conflicted]
      )

      flags = described_class.new(receipt: receipt).error_flags

      aggregate_failures do
        expect(flags[:store_name]).to be(true)
        expect(flags[:payment_method]).to be(true)
        expect(flags[:purchased_at]).to be(true)
        expect(flags[:store_address]).to be(false)
      end
    end

    it '支払方法欠損理由を支払方法フィールドへ割り当てる' do
      receipt = build(:receipt, payment_method: nil, review_reasons: [ 'payment_method_missing' ])

      expect(described_class.new(receipt: receipt).error_flags[:payment_method]).to be(true)
    end
  end

  describe '#item_row' do
    it '新規明細のcategoryを422再表示用の選択値として保持する' do
      receipt = build(:receipt)
      item = receipt.receipt_items.build(category: 'medical')

      row = described_class.new(receipt: receipt).item_row(item, new_record: true)

      expect(row.selected_category).to eq('medical')
    end

    it 'builds item row state from review reasons and quantity unit' do
      receipt = build(:receipt)
      item = ReceiptItem.new(
        receipt: receipt,
        quantity_unit_code: 'kilogram',
        tax_rate: BigDecimal('0.08'),
        needs_review: true,
        review_reasons: %w[item_name_uncertain item_tax_rate_uncertain price_tax_inclusion_uncertain]
      )

      row = described_class.new(receipt: receipt).item_row(item, new_record: false)

      aggregate_failures do
        expect(row.selected_unit).to eq('kilogram')
        expect(row.quantity_step).to eq('0.001')
        expect(row.quantity_inputmode).to eq('decimal')
        expect(row.name_highlight_variant).to eq(:error)
        expect(row.tax_rate_highlight_variant).to eq(:error)
        expect(row.tax_rate_percentage_value).to eq(8)
        expect(row.warning_reason_labels).to be_present
      end
    end

    it '計算方式reasonを持つreview対象Itemだけ計算方式selectを強調する' do
      receipt = build(:receipt)
      reviewed_item = ReceiptItem.new(
        receipt: receipt,
        pricing_source_kind: 'explicit_line_total',
        original_line_total: 100,
        line_total: 100,
        needs_review: true,
        review_reasons: [ 'item_pricing_mode_uncertain' ]
      )
      warning_only_item = reviewed_item.dup.tap { |item| item.needs_review = false }
      unrelated_item = reviewed_item.dup.tap do |item|
        item.review_reasons = [ 'item_name_uncertain' ]
      end

      reviewed_row = described_class.new(receipt: receipt).item_row(reviewed_item, new_record: false)
      warning_only_row = described_class.new(receipt: receipt).item_row(warning_only_item, new_record: false)
      unrelated_row = described_class.new(receipt: receipt).item_row(unrelated_item, new_record: false)

      aggregate_failures do
        expect(reviewed_row.pricing_source_review?).to be(true)
        expect(reviewed_row.pricing_source_kind_highlight_variant).to eq(:error)
        expect(reviewed_row.row_class).to include('receipt-form-item-details-open')
        expect(warning_only_row.pricing_source_review?).to be(false)
        expect(warning_only_row.pricing_source_kind_highlight_variant).to be_nil
        expect(unrelated_row.pricing_source_review?).to be(false)
        expect(unrelated_row.pricing_source_kind_highlight_variant).to be_nil
      end
    end

    it '保存済みoriginalが0の場合はline totalをsource baselineとして渡し、422ではsubmitted sourceを優先する' do
      receipt = create(:receipt)
      item = receipt.receipt_items.create!(
        confirmed_name: '商品',
        price: 500,
        quantity: 1,
        quantity_unit_code: 'each',
        original_line_total: 0,
        line_total: 500,
        tax_rate: 0
      )

      persisted_row = described_class.new(receipt: receipt).item_row(item, new_record: false)
      submitted_row = described_class.new(
        receipt: receipt,
        submitted_params: {
          receipt_items_attributes: {
            '0' => { id: item.id, original_line_total: '700', line_total: '630' }
          }
        }
      ).item_row(item, new_record: false)

      aggregate_failures do
        expect(persisted_row.original_line_total_value).to eq(500)
        expect(persisted_row.line_total_data[:original_line_total]).to eq(500)
        expect(submitted_row.original_line_total_value).to eq('700')
        expect(submitted_row.line_total_value).to eq('630')
      end
    end

    it 'measurementの422では入力中の単価・数量・単位・明示小計をそのまま再表示する' do
      receipt = create(:receipt)
      item = receipt.receipt_items.create!(
        confirmed_name: '計量商品',
        price: 140,
        quantity: BigDecimal('8.12'),
        quantity_unit_code: 'liter',
        original_line_total: 1_137,
        line_total: 1_137,
        tax_rate: 0
      )
      row = described_class.new(
        receipt: receipt,
        submitted_params: {
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              price: '141',
              quantity: '0',
              quantity_unit_code: 'milliliter',
              original_line_total: '1200',
              line_total: '1200'
            }
          }
        }
      ).item_row(item, new_record: false)

      aggregate_failures do
        expect(row.price_value).to eq('141')
        expect(row.quantity_value).to eq('0')
        expect(row.selected_unit).to eq('milliliter')
        expect(row.original_line_total_value).to eq('1200')
        expect(row.line_total_value).to eq('1200')
        expect(row.line_total_data[:original_line_total]).to eq('1200')
      end
    end

    it 'original 0だけのplaceholderを明示line total 0へ昇格させない' do
      receipt = build(:receipt)
      item = ReceiptItem.new(
        receipt: receipt,
        price: nil,
        quantity: 1,
        quantity_unit_code: 'each',
        original_line_total: 0,
        line_total: nil
      )

      row = described_class.new(receipt: receipt).item_row(item, new_record: false)

      aggregate_failures do
        expect(row.original_line_total_value).to be_nil
        expect(row.line_total_value).to be_nil
      end
    end

    it '新規行は単価と数量を初期authorityとし、参照価格の税区分を税込に固定する' do
      receipt = build(:receipt)
      item = receipt.receipt_items.build

      row = described_class.new(receipt: receipt).item_row(item, new_record: true)

      aggregate_failures do
        expect(row.pricing_source_kind_value).to eq('count_unit_price')
        expect(row.pricing_source_ui_mode).to eq('count_unit_price')
        expect(row.reference_price_tax_inclusion_value).to eq('gross')
        expect(row.reference_price_tax_inclusion_label).to eq('税込基準')
        expect(row.pricing_source_mode_options.map(&:last)).to eq(
          %w[count_unit_price reference_quantity_price explicit_line_total]
        )
      end
    end

    it '保存済み税抜reference authorityを表示・再表示用のsourceとして維持する' do
      receipt = build(:receipt)
      item = receipt.receipt_items.build(
        pricing_source_kind: 'reference_quantity_price',
        reference_price_amount: BigDecimal('120.5'),
        reference_quantity: BigDecimal('0.5'),
        reference_quantity_unit_code: 'liter',
        reference_price_tax_inclusion: 'net',
        quantity: BigDecimal('1.25'),
        quantity_unit_code: 'liter',
        line_total: 332
      )

      row = described_class.new(receipt: receipt).item_row(item, new_record: false)

      aggregate_failures do
        expect(row.pricing_source_ui_mode).to eq('reference_quantity_price')
        expect(row.reference_price_amount_value).to eq('120.5')
        expect(row.reference_quantity_value).to eq('0.5')
        expect(row.selected_reference_quantity_unit).to eq('liter')
        expect(row.reference_price_tax_inclusion_value).to eq('net')
        expect(row.reference_price_tax_inclusion_label).to eq('税抜基準')
        expect(row.pricing_source_summary_for(row.pricing_source_ui_mode)).to eq('120.5円 / 0.5L（税抜）')
      end
    end

    it '422再表示で選択中modeとtyped reference sourceをDB値より優先する' do
      receipt = create(:receipt)
      item = receipt.receipt_items.create!(
        confirmed_name: '計量商品',
        pricing_source_kind: 'reference_quantity_price',
        reference_price_amount: BigDecimal('120'),
        reference_quantity: BigDecimal('500'),
        reference_quantity_unit_code: 'milliliter',
        reference_price_tax_inclusion: 'net',
        quantity: BigDecimal('1'),
        quantity_unit_code: 'liter',
        line_total: 264
      )
      row = described_class.new(
        receipt: receipt,
        submitted_params: {
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              pricing_source_kind: 'reference_quantity_price',
              reference_price_amount: '130.000001',
              reference_quantity: '0.250',
              reference_quantity_unit_code: 'liter',
              reference_price_tax_inclusion: 'net'
            }
          }
        }
      ).item_row(item, new_record: false)

      aggregate_failures do
        expect(row.pricing_source_kind_value).to eq('reference_quantity_price')
        expect(row.reference_price_amount_value).to eq('130.000001')
        expect(row.reference_quantity_value).to eq('0.250')
        expect(row.selected_reference_quantity_unit).to eq('liter')
        expect(row.reference_price_tax_inclusion_value).to eq('net')
      end
    end

    it '割引解除を確認した明示金額切替intentを422再表示で維持する' do
      receipt = create(:receipt)
      item = receipt.receipt_items.create!(
        confirmed_name: '割引商品',
        pricing_source_kind: 'reference_quantity_price',
        quantity: BigDecimal('1'),
        quantity_unit_code: 'each',
        reference_price_amount: BigDecimal('200'),
        reference_quantity: BigDecimal('1'),
        reference_quantity_unit_code: 'each',
        reference_price_tax_inclusion: 'gross',
        original_line_total: 200,
        line_total: 180,
        discount_amount: 20,
        discount_rate: BigDecimal('0.1')
      )
      presenter = described_class.new(
        receipt: receipt,
        submitted_params: {
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              pricing_source_kind: 'explicit_line_total',
              original_line_total: '200',
              clear_item_discount_before_explicit: '1'
            }
          }
        }
      )
      row = presenter.item_row(item, new_record: false)

      aggregate_failures do
        expect(row.clear_item_discount_before_explicit_value).to eq('1')
        expect(row.discount_source_present?).to be(false)
        expect(row.explicit_line_total_label).to eq('明細金額')
        expect(row.pricing_source_summary_for(row.pricing_source_ui_mode)).to eq('明細金額 200円')
      end
    end

    it '割引解除確認後のblankと新しい0%入力を異なるexplicit sourceとして表示する' do
      receipt = create(:receipt)
      item = receipt.receipt_items.create!(
        confirmed_name: '0率確認商品',
        pricing_source_kind: 'reference_quantity_price',
        quantity: 1,
        quantity_unit_code: 'each',
        reference_price_amount: 200,
        reference_quantity: 1,
        reference_quantity_unit_code: 'each',
        reference_price_tax_inclusion: 'gross',
        original_line_total: 200,
        line_total: 200,
        discount_rate: BigDecimal('0'),
        discount_amount: 0
      )
      row_for = lambda do |discount_rate:, submitted:|
        described_class.new(
          receipt: receipt,
          submitted_params: {
            receipt_items_attributes: {
              '0' => {
                id: item.id,
                pricing_source_kind: 'explicit_line_total',
                original_line_total: '200',
                clear_item_discount_before_explicit: '1'
              }.merge(submitted ? { discount_rate: discount_rate } : {})
            }
          }
        ).item_row(item, new_record: false)
      end

      aggregate_failures do
        expect(row_for.call(discount_rate: '', submitted: true).discount_source_present?).to be(false)
        expect(row_for.call(discount_rate: nil, submitted: false).discount_source_present?).to be(false)
        expect(row_for.call(discount_rate: '0', submitted: true).discount_source_present?).to be(true)
        expect(row_for.call(discount_rate: '10', submitted: true).discount_source_present?).to be(true)
        expect(row_for.call(discount_rate: '0', submitted: true).explicit_line_total_label).to eq('割引前明細金額')
      end
    end

    it '422再表示はclear intentなしで保存済みabsolute discount sourceを失わない' do
      receipt = create(:receipt)
      build_persisted_item = lambda do |name, discount_amount|
        receipt.receipt_items.create!(
          confirmed_name: name,
          pricing_source_kind: 'count_unit_price',
          price: 180,
          quantity: 1,
          quantity_unit_code: 'each',
          original_line_total: 180,
          line_total: 180
        ).tap do |item|
          item.update_columns(
            pricing_source_kind: 'explicit_line_total',
            price: nil,
            original_line_total: nil,
            line_total: 180,
            discount_rate: nil,
            discount_amount: discount_amount
          )
        end
      end
      positive_amount_item = build_persisted_item.call('正の割引', 20)
      zero_amount_item = build_persisted_item.call('0円割引', 0)

      row_for = lambda do |item:, discount_rate:, clear_intent: '0'|
        described_class.new(
          receipt: receipt,
          submitted_params: {
            receipt_items_attributes: {
              '0' => {
                id: item.id,
                pricing_source_kind: 'explicit_line_total',
                original_line_total: '',
                discount_rate: discount_rate,
                clear_item_discount_before_explicit: clear_intent
              }
            }
          }
        ).item_row(item, new_record: false)
      end

      aggregate_failures do
        [ '', '0' ].each do |submitted_rate|
          positive_row = row_for.call(item: positive_amount_item, discount_rate: submitted_rate)
          expect(positive_row.discount_source_present?).to be(true)
          expect(positive_row.explicit_line_total_value).to be_nil
          expect(positive_row.explicit_line_total_source_missing?).to be(true)
          expect(positive_row.pricing_source_summary_for(positive_row.pricing_source_ui_mode)).to eq('割引前明細金額')

          zero_row = row_for.call(item: zero_amount_item, discount_rate: submitted_rate)
          expect(zero_row.discount_source_present?).to be(true)
          expect(zero_row.explicit_line_total_value).to eq(180)
          expect(zero_row.explicit_line_total_source_missing?).to be(false)
          expect(zero_row.pricing_source_summary_for(zero_row.pricing_source_ui_mode)).to eq('割引前明細金額 180円')
        end

        cleared_row = row_for.call(item: positive_amount_item, discount_rate: '', clear_intent: '1')
        expect(cleared_row.discount_source_present?).to be(false)
        expect(cleared_row.explicit_line_total_value).to eq(180)
        expect(cleared_row.explicit_line_total_source_missing?).to be(false)
        expect(cleared_row.pricing_source_summary_for(cleared_row.pricing_source_ui_mode)).to eq('明細金額 180円')
      end
    end

    it '422再表示は曖昧なexplicit行の保存済みpositive rateをblankや0で失わない' do
      receipt = create(:receipt)
      item = receipt.receipt_items.create!(
        confirmed_name: '正率割引',
        pricing_source_kind: 'count_unit_price',
        price: 200,
        quantity: 1,
        quantity_unit_code: 'each',
        original_line_total: 200,
        line_total: 180,
        discount_rate: BigDecimal('0.1'),
        discount_amount: nil
      )
      item.update_columns(
        pricing_source_kind: 'explicit_line_total',
        price: nil,
        original_line_total: nil
      )

      row_for = lambda do |discount_rate:, clear_intent: '0'|
        described_class.new(
          receipt: receipt,
          submitted_params: {
            receipt_items_attributes: {
              '0' => {
                id: item.id,
                pricing_source_kind: 'explicit_line_total',
                original_line_total: '',
                discount_rate: discount_rate,
                clear_item_discount_before_explicit: clear_intent
              }
            }
          }
        ).item_row(item, new_record: false)
      end

      aggregate_failures do
        [ '', '0' ].each do |submitted_rate|
          row = row_for.call(discount_rate: submitted_rate)
          expect(row.discount_source_present?).to be(true)
          expect(row.explicit_line_total_value).to be_nil
          expect(row.explicit_line_total_source_missing?).to be(true)
          expect(row.explicit_line_total_label).to eq('割引前明細金額')
          expect(row.pricing_source_summary_for(row.pricing_source_ui_mode)).to eq('割引前明細金額')
          expect(row.line_total_value).to eq(180)
        end

        cleared_row = row_for.call(discount_rate: '', clear_intent: '1')
        expect(cleared_row.discount_source_present?).to be(false)
        expect(cleared_row.explicit_line_total_value).to eq(180)
        expect(cleared_row.explicit_line_total_source_missing?).to be(false)
        expect(cleared_row.pricing_source_summary_for(cleared_row.pricing_source_ui_mode)).to eq('明細金額 180円')
      end
    end

    it '保存済みformulaの明示0 discountをnilと区別する' do
      receipt = build(:receipt)
      zero_rate = receipt.receipt_items.build(
        pricing_source_kind: 'count_unit_price', discount_rate: BigDecimal('0'), discount_amount: nil
      )
      zero_amount = receipt.receipt_items.build(
        pricing_source_kind: 'count_unit_price', discount_rate: nil, discount_amount: 0
      )
      absent = receipt.receipt_items.build(
        pricing_source_kind: 'count_unit_price', discount_rate: nil, discount_amount: nil
      )
      presenter = described_class.new(receipt: receipt)

      aggregate_failures do
        expect(presenter.item_row(zero_rate, new_record: false).discount_source_present?).to be(true)
        expect(presenter.item_row(zero_amount, new_record: false).discount_source_present?).to be(true)
        expect(presenter.item_row(absent, new_record: false).discount_source_present?).to be(false)
      end
    end

    it 'authority kind未記録行を曖昧な呼称にまとめず保存済み金額の意味で要約する' do
      receipt = build(:receipt)
      count_item = receipt.receipt_items.build(
        price: 80, quantity: 2, quantity_unit_code: 'each', line_total: 160
      )
      measurement_item = receipt.receipt_items.build(
        price: 80, quantity: BigDecimal('1.5'), quantity_unit_code: 'liter', line_total: 120
      )
      amount_missing_item = receipt.receipt_items.build(
        quantity: BigDecimal('1.5'), quantity_unit_code: 'liter', line_total: nil
      )

      count_row = described_class.new(receipt: receipt).item_row(count_item, new_record: false)
      measurement_row = described_class.new(receipt: receipt).item_row(measurement_item, new_record: false)
      missing_row = described_class.new(receipt: receipt).item_row(amount_missing_item, new_record: false)

      aggregate_failures do
        expect(count_row.pricing_source_ui_mode).to eq('unclassified')
        expect(count_row.pricing_source_summary_for(count_row.pricing_source_ui_mode)).to eq('80円 × 2個（方式未記録）')
        expect(measurement_row.pricing_source_summary_for(measurement_row.pricing_source_ui_mode)).to eq('保存済み明細金額 120円（方式未記録）')
        expect(missing_row.pricing_source_summary_for(missing_row.pricing_source_ui_mode)).to eq('金額未設定（方式未記録）')
      end
    end

    it '明示金額authorityは割引前sourceと割引済みpreviewを分け、discount source有無を渡す' do
      receipt = build(:receipt)
      item = receipt.receipt_items.build(
        pricing_source_kind: 'explicit_line_total',
        quantity: 1,
        quantity_unit_code: 'each',
        original_line_total: 200,
        line_total: 180,
        discount_amount: 20
      )

      row = described_class.new(receipt: receipt).item_row(item, new_record: false)

      aggregate_failures do
        expect(row.explicit_line_total_value).to eq(200)
        expect(row.pricing_source_summary_for(row.pricing_source_ui_mode)).to eq('割引前明細金額 200円')
        expect(row.discount_source_present?).to be(true)
        expect(row.explicit_line_total_label).to eq('割引前明細金額')
      end
    end

    it '明示金額authorityはoriginalの有無と実効割引を分けて可視sourceを決める' do
      receipt = build(:receipt)
      missing_before_amount_discount = receipt.receipt_items.build(
        pricing_source_kind: 'explicit_line_total',
        original_line_total: nil,
        line_total: 180,
        discount_amount: 20
      )
      missing_before_rate_discount = receipt.receipt_items.build(
        pricing_source_kind: 'explicit_line_total',
        original_line_total: nil,
        line_total: 180,
        discount_rate: BigDecimal('0.1'),
        discount_amount: nil
      )
      explicit_zero_with_stale_derived = receipt.receipt_items.build(
        pricing_source_kind: 'explicit_line_total',
        original_line_total: 0,
        line_total: 15,
        discount_amount: 20
      )
      zero_only_discount = receipt.receipt_items.build(
        pricing_source_kind: 'explicit_line_total',
        original_line_total: nil,
        line_total: 180,
        discount_rate: BigDecimal('0'),
        discount_amount: 0
      )
      presenter = described_class.new(receipt: receipt)

      missing_amount_row = presenter.item_row(missing_before_amount_discount, new_record: false)
      missing_rate_row = presenter.item_row(missing_before_rate_discount, new_record: false)
      zero_row = presenter.item_row(explicit_zero_with_stale_derived, new_record: false)
      zero_discount_row = presenter.item_row(zero_only_discount, new_record: false)

      aggregate_failures do
        [ missing_amount_row, missing_rate_row ].each do |missing_row|
          expect(missing_row.explicit_line_total_value).to be_nil
          expect(missing_row.explicit_line_total_source_missing?).to be(true)
          expect(missing_row.pricing_source_summary_for(missing_row.pricing_source_ui_mode)).to eq('割引前明細金額')
          expect(missing_row.line_total_value).to eq(180)
          expect(missing_row.line_total_data[:original_line_total]).to be_nil
        end

        expect(zero_row.explicit_line_total_value).to eq(0)
        expect(zero_row.explicit_line_total_source_missing?).to be(false)
        expect(zero_row.pricing_source_summary_for(zero_row.pricing_source_ui_mode)).to eq('割引前明細金額 0円')

        expect(zero_discount_row.explicit_line_total_value).to eq(180)
        expect(zero_discount_row.explicit_line_total_source_missing?).to be(false)
        expect(zero_discount_row.pricing_source_summary_for(zero_discount_row.pricing_source_ui_mode)).to eq('割引前明細金額 180円')
      end
    end
  end

  describe '#adjustment_row' do
    it 'builds adjustment row state from kind and tax rate' do
      receipt = build(:receipt)
      adjustment = build(:receipt_adjustment, receipt: receipt, kind: 'other', sign: nil, tax_rate: BigDecimal('0.1'))

      row = described_class.new(receipt: receipt).adjustment_row(adjustment, new_record: false)

      aggregate_failures do
        expect(row.selected_kind).to eq('other')
        expect(row.selected_sign).to eq('discount')
        expect(row.other_kind?).to be(true)
        expect(row.sign_select_disabled?).to be(false)
        expect(row.tax_rate_value).to eq(10)
      end
    end


    it 'source_text由来のpayment分類を内容を露出せずrow stateへ渡す' do
      receipt = build(:receipt)
      adjustment = build(
        :receipt_adjustment,
        receipt: receipt,
        kind: 'receipt_discount',
        label: '還元額',
        source_text: 'キャッシュレス還元額 -22',
        source: 'ai'
      )

      row = described_class.new(receipt: receipt).adjustment_row(adjustment, new_record: false)

      aggregate_failures do
        expect(row.calculation_effect).to eq('payment_adjustment')
        expect(row.source_text_payment_adjustment?).to be(true)
        expect(row.source_non_manual?).to be(true)
      end
    end
  end
end
