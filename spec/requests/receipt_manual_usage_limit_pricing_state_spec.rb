require 'rails_helper'

RSpec.describe 'Manual receipt usage limit pricing state', type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
    create(:usage_counter, user: user, key: 'manual_receipts_per_day', used_count: 50)
  end

  def reference_item_attributes(name:, quantity:, unit:, price:, reference_quantity:, reference_unit:)
    {
      confirmed_name: name,
      quantity: quantity,
      quantity_unit_code: unit,
      tax_rate: '0',
      discount_rate: '',
      pricing_source_kind: 'reference_quantity_price',
      reference_price_amount: price,
      reference_quantity: reference_quantity,
      reference_quantity_unit_code: reference_unit,
      reference_price_tax_inclusion: 'gross',
      original_line_total: '',
      line_total: '',
      _destroy: '0'
    }
  end

  def rendered_item_rows(document)
    document.css(
      '[data-receipt-form-target="itemsContainer"] > ' \
      '[data-controller~="swipe-action"] [data-receipt-form-target="itemRow"]'
    )
  end

  def rendered_item_row(rows, name)
    rows.find do |row|
      row.at_css("input[name$='[confirmed_name]']")&.[]('value') == name
    end
  end

  def rendered_adjustment_rows(document)
    document.css('[data-receipt-form-target="adjustmentRow"]').reject do |row|
      row.ancestors.any? { |ancestor| ancestor.name == 'template' }
    end
  end

  def adjustment_attributes
    {
      kind: 'delivery_fee',
      label: '配送料',
      amount: '550',
      sign: 'surcharge',
      tax_rate: '10',
      _destroy: '0'
    }
  end

  def selected_value(row, field)
    row.at_css("select[name$='[#{field}]'] option[selected]")&.[]('value')
  end

  def input_value(row, field)
    row.at_css("input[name$='[#{field}]']")&.[]('value')
  end

  def persisted_explicit_item_attributes(item)
    {
      id: item.id,
      confirmed_name: item.confirmed_name,
      quantity: '1',
      quantity_unit_code: 'each',
      tax_rate: '0',
      discount_rate: '',
      pricing_source_kind: 'explicit_line_total',
      original_line_total: '0',
      line_total: '0',
      _destroy: '0'
    }
  end

  def create_zero_receipt(item_count:)
    receipt = create(
      :receipt,
      :completed,
      user: user,
      store_name: '保存済み0円店',
      payment_method: 'cash',
      subtotal_amount: 0,
      tax_amount: 0,
      total_amount: 0,
      review_reasons: []
    )
    item_count.times do |index|
      receipt.receipt_items.create!(
        confirmed_name: "保存済み0円商品#{index + 1}",
        quantity: BigDecimal('1'),
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0'),
        pricing_source_kind: 'explicit_line_total',
        original_line_total: 0,
        line_total: 0,
        needs_review: false,
        review_reasons: []
      )
    end
    receipt
  end

  def persisted_graph_snapshot(receipt)
    receipt.reload
    {
      receipt: receipt.attributes.deep_dup,
      items: receipt.receipt_items.reload.sort_by(&:id).map { |item| item.attributes.deep_dup },
      adjustments: receipt.receipt_adjustments.reload.sort_by(&:id).map { |adjustment| adjustment.attributes.deep_dup }
    }
  end

  it '日次上限の422でA/空/Cから空行をpruneしreference sourceと新規adjustmentを重複なく保持する' do
    submitted_items = {
      '0' => reference_item_attributes(
        name: '基準価格商品A',
        quantity: '1.0',
        unit: 'liter',
        price: '1000.0',
        reference_quantity: '1000.5',
        reference_unit: 'milliliter'
      ),
      '1' => {
        confirmed_name: '',
        quantity: '1',
        quantity_unit_code: 'each',
        tax_rate: '',
        discount_rate: '',
        pricing_source_kind: 'count_unit_price',
        price: '',
        original_line_total: '',
        line_total: '',
        _destroy: '0'
      },
      '2' => reference_item_attributes(
        name: '基準価格商品C',
        quantity: '2.0',
        unit: 'liter',
        price: '45.6',
        reference_quantity: '0.5',
        reference_unit: 'liter'
      ),
      '3' => reference_item_attributes(
        name: '削除済み基準価格商品D',
        quantity: '4.0',
        unit: 'liter',
        price: '400.0',
        reference_quantity: '1000.0',
        reference_unit: 'milliliter'
      ).merge(_destroy: '1')
    }

    expect do
      post receipts_path, params: {
        receipt: {
          store_name: '日次上限source保持店',
          payment_method: 'cash',
          receipt_items_attributes: submitted_items,
          receipt_adjustments_attributes: {
            '0' => adjustment_attributes,
            '1' => {
              kind: 'delivery_fee',
              label: '',
              amount: '',
              sign: 'surcharge',
              tax_rate: '',
              _destroy: '0'
            }
          }
        }
      }
    end.not_to change(Receipt, :count)

    document = Nokogiri::HTML(response.body)
    rows = rendered_item_rows(document)

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('flash.usage_limits.manual_receipts_exceeded'))
      expect(rows.size).to eq(2)
      expect(rows.filter_map { |row| input_value(row, 'confirmed_name') }).to contain_exactly(
        '基準価格商品A',
        '基準価格商品C'
      )
      expect(rendered_adjustment_rows(document).size).to eq(1)
      expect(input_value(rendered_adjustment_rows(document).sole, 'amount')).to eq('550')
      expect(user.receipts.where(store_name: '日次上限source保持店')).to be_empty
      expect(UsageCounter.find_by!(user: user, key: 'manual_receipts_per_day').used_count).to eq(50)
    end

    submitted_items.slice('0', '2').each_value do |source|
      row = rendered_item_row(rows, source.fetch(:confirmed_name))

      aggregate_failures source.fetch(:confirmed_name) do
        expect(row).to be_present
        expect(selected_value(row, 'pricing_source_kind')).to eq('reference_quantity_price')
        expect(input_value(row, 'quantity')).to eq(source.fetch(:quantity))
        expect(selected_value(row, 'quantity_unit_code')).to eq(source.fetch(:quantity_unit_code))
        expect(input_value(row, 'reference_price_amount')).to eq(source.fetch(:reference_price_amount))
        expect(input_value(row, 'reference_quantity')).to eq(source.fetch(:reference_quantity))
        expect(selected_value(row, 'reference_quantity_unit_code')).to eq(source.fetch(:reference_quantity_unit_code))
        expect(input_value(row, 'reference_price_tax_inclusion')).to eq('gross')
      end
    end
  end

  it 'model validation 422で新規adjustmentを1行だけ再表示しDBへ保存しない' do
    UsageCounter.where(user: user, key: 'manual_receipts_per_day').delete_all

    expect do
      post receipts_path, params: {
        receipt: {
          store_name: '',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: 'validation確認商品',
              quantity: '1',
              quantity_unit_code: 'each',
              tax_rate: '10',
              discount_rate: '',
              pricing_source_kind: 'explicit_line_total',
              original_line_total: '1000',
              line_total: '',
              _destroy: '0'
            }
          },
          receipt_adjustments_attributes: { '0' => adjustment_attributes }
        }
      }
    end.not_to change(Receipt, :count)

    adjustment_rows = rendered_adjustment_rows(Nokogiri::HTML(response.body))

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(adjustment_rows.size).to eq(1)
      expect(input_value(adjustment_rows.sole, 'label')).to eq('配送料')
      expect(input_value(adjustment_rows.sole, 'amount')).to eq('550')
    end
  end

  it 'editの計算後amount上限422で新規count行のmodeとraw sourceを保持しDBを変更しない' do
    receipt = create_zero_receipt(item_count: 3)
    before = persisted_graph_snapshot(receipt)
    submitted_items = receipt.receipt_items.each_with_index.to_h do |item, index|
      [ index.to_s, persisted_explicit_item_attributes(item) ]
    end
    submitted_items['3'] = {
      confirmed_name: '上限超過商品',
      quantity: '2',
      quantity_unit_code: 'each',
      tax_rate: '0',
      discount_rate: '',
      pricing_source_kind: 'count_unit_price',
      price: ReceiptAmountService.receipt_item_price_max.to_s,
      original_line_total: '',
      line_total: '',
      _destroy: '0'
    }
    submitted_adjustments = { '0' => adjustment_attributes }

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: submitted_items,
        receipt_adjustments_attributes: submitted_adjustments
      }
    }

    document = Nokogiri::HTML(response.body)
    rows = rendered_item_rows(document)
    added_row = rendered_item_row(rows, '上限超過商品')

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('receipts.form.errors.amount_limit_exceeded',
        resource: 'receipt_items',
        field: 'line_total',
        limit: ReceiptAmountService.receipt_item_line_total_max,
        actual_value: ReceiptAmountService.receipt_item_price_max * 2))
      expect(rows.size).to eq(4)
      expect(added_row).to be_present
      expect(selected_value(added_row, 'pricing_source_kind')).to eq('count_unit_price')
      expect(input_value(added_row, 'quantity')).to eq('2')
      expect(selected_value(added_row, 'quantity_unit_code')).to eq('each')
      expect(input_value(added_row, 'price')).to eq(ReceiptAmountService.receipt_item_price_max.to_s)
      expect(rendered_adjustment_rows(document).size).to eq(1)
      expect(input_value(rendered_adjustment_rows(document).sole, 'amount')).to eq('550')
      expect(persisted_graph_snapshot(receipt)).to eq(before)
    end
  end

  it 'editのinvalid numeric 422で新規reference行の税込basisを含むsourceを保持し、価格だけの修正で保存する' do
    receipt = create_zero_receipt(item_count: 1)
    before = persisted_graph_snapshot(receipt)
    existing_item = receipt.receipt_items.sole
    submitted_items = {
      '0' => persisted_explicit_item_attributes(existing_item),
      '1' => reference_item_attributes(
        name: '修正待ち基準価格商品',
        quantity: '1.5',
        unit: 'liter',
        price: '1e2',
        reference_quantity: '500',
        reference_unit: 'milliliter'
      )
    }

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: submitted_items
      }
    }

    rows = rendered_item_rows(Nokogiri::HTML(response.body))
    added_row = rendered_item_row(rows, '修正待ち基準価格商品')

    aggregate_failures 'invalid response' do
      expect(response).to have_http_status(:unprocessable_content)
      expect(rows.size).to eq(2)
      expect(selected_value(added_row, 'pricing_source_kind')).to eq('reference_quantity_price')
      expect(input_value(added_row, 'quantity')).to eq('1.5')
      expect(selected_value(added_row, 'quantity_unit_code')).to eq('liter')
      expect(input_value(added_row, 'reference_price_amount')).to eq('1e2')
      expect(input_value(added_row, 'reference_quantity')).to eq('500')
      expect(selected_value(added_row, 'reference_quantity_unit_code')).to eq('milliliter')
      expect(input_value(added_row, 'reference_price_tax_inclusion')).to eq('gross')
      expect(persisted_graph_snapshot(receipt)).to eq(before)
    end

    submitted_items['1'][:reference_price_amount] = '120.5'
    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.reload.lock_version,
        receipt_items_attributes: submitted_items
      }
    }

    saved_item = receipt.reload.receipt_items.find_by!(confirmed_name: '修正待ち基準価格商品')
    aggregate_failures 'corrected response' do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.receipt_items.count).to eq(2)
      expect(saved_item).to have_attributes(
        pricing_source_kind: 'reference_quantity_price',
        quantity: BigDecimal('1.5'),
        quantity_unit_code: 'liter',
        reference_price_amount: BigDecimal('120.5'),
        reference_quantity: BigDecimal('500'),
        reference_quantity_unit_code: 'milliliter',
        reference_price_tax_inclusion: 'gross'
      )
    end
  end
end
