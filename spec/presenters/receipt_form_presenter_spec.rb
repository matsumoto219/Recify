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

  describe '#adjustment_tax_detail_rates_value' do
    it '金額を持つ保存済みtax detailの税率だけをpercentageで渡し、不明rateも保持する' do
      receipt = create(:receipt)
      receipt.receipt_tax_details.create!(rate: BigDecimal('0.1'), net_amount: 100, amount: 10)
      receipt.receipt_tax_details.create!(rate: BigDecimal('0.08'), net_amount: 0, amount: 0)
      receipt.receipt_tax_details.create!(rate: nil, net_amount: 50, amount: 0)

      expect(described_class.new(receipt: receipt).adjustment_tax_detail_rates_value).to eq([ '10', nil ])
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
