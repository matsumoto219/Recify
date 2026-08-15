require 'rails_helper'

RSpec.describe 'Receipt measurement amount contract', type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  def create_measurement_receipt
    receipt = create(
      :receipt,
      user: user,
      status: 'completed',
      store_name: '計量契約店',
      purchased_at: 1.day.ago,
      payment_method: 'cash',
      subtotal_amount: 1_137,
      tax_amount: 0,
      total_amount: 1_137,
      review_reasons: []
    )
    item = receipt.receipt_items.create!(
      confirmed_name: '計量商品',
      price: 140,
      quantity: BigDecimal('8.12'),
      quantity_unit_code: 'liter',
      tax_rate: BigDecimal('0'),
      original_line_total: 1_137,
      line_total: 1_137,
      needs_review: false,
      review_reasons: []
    )

    [ receipt, item ]
  end

  def measurement_item_attributes(item, overrides = {})
    {
      id: item.id,
      confirmed_name: item.confirmed_name,
      category: item.category,
      price: item.price.to_s,
      quantity: item.quantity.to_s,
      quantity_unit_code: item.quantity_unit_code,
      product_code: item.product_code,
      tax_rate: '0',
      discount_rate: '',
      original_line_total: item.original_line_total.to_s,
      line_total: item.line_total.to_s,
      position_index: item.position_index,
      _destroy: '0'
    }.merge(overrides)
  end

  def patch_measurement(receipt, item, overrides = {})
    receipt.reload
    item.reload

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        receipt_items_attributes: {
          '0' => measurement_item_attributes(item, overrides)
        }
      }
    }
  end

  def persisted_amount_snapshot(receipt, item)
    receipt.reload
    item.reload

    {
      receipt: receipt.attributes.slice('subtotal_amount', 'tax_amount', 'total_amount', 'status'),
      item: item.attributes.slice('price', 'quantity', 'quantity_unit_code', 'original_line_total', 'line_total')
    }
  end

  def rendered_item_row(document, item_id: nil, item_name: nil)
    document.css('[data-receipt-form-target="itemRow"]').find do |row|
      id_matches = item_id && row.at_css("input[name$='[id]']")&.[]('value') == item_id.to_s
      name_matches = item_name && row.at_css("input[name$='[confirmed_name]']")&.[]('value') == item_name
      id_matches || name_matches
    end
  end

  it '8.12Lと9.12Lの保存往復で明示小計とReceipt合計を変えない' do
    receipt, item = create_measurement_receipt

    patch_measurement(receipt, item, quantity: '9.12')
    first_save = persisted_amount_snapshot(receipt, item)

    expect(response).to redirect_to(receipt_path(receipt))
    get edit_receipt_path(receipt)
    first_reload_row = rendered_item_row(Nokogiri::HTML(response.body), item_id: item.id)

    patch_measurement(receipt, item, quantity: '9.12')
    same_value_save = persisted_amount_snapshot(receipt, item)

    expect(response).to redirect_to(receipt_path(receipt))
    get edit_receipt_path(receipt)
    second_reload_row = rendered_item_row(Nokogiri::HTML(response.body), item_id: item.id)

    patch_measurement(receipt, item, quantity: '8.12')
    restored_save = persisted_amount_snapshot(receipt, item)

    aggregate_failures do
      expect(first_reload_row.at_css("input[name$='[quantity]']")['value']).to eq('9.12')
      expect(first_reload_row.at_css("input[name$='[original_line_total]']")['value']).to eq('1137')
      expect(first_reload_row.at_css("input[name$='[line_total]']")['value']).to eq('1137')
      expect(second_reload_row.at_css("input[name$='[quantity]']")['value']).to eq('9.12')
      expect(first_save).to eq(
        receipt: {
          'subtotal_amount' => 1_137,
          'tax_amount' => 0,
          'total_amount' => 1_137,
          'status' => 'completed'
        },
        item: {
          'price' => 140,
          'quantity' => BigDecimal('9.12'),
          'quantity_unit_code' => 'liter',
          'original_line_total' => 1_137,
          'line_total' => 1_137
        }
      )
      expect(same_value_save).to eq(first_save)
      expect(restored_save).to eq(first_save.deep_merge(
        item: { 'quantity' => BigDecimal('8.12') }
      ))
    end
  end

  it '不正quantityの422で入力sourceを再表示しDBを変更しない' do
    receipt, item = create_measurement_receipt
    persisted_before = persisted_amount_snapshot(receipt, item)
    lock_version_before = receipt.lock_version

    patch_measurement(
      receipt,
      item,
      price: '141',
      quantity: '0',
      quantity_unit_code: 'milliliter',
      original_line_total: '1200',
      line_total: '1200'
    )

    document = Nokogiri::HTML(response.body)
    rendered_row = rendered_item_row(document, item_id: item.id)
    selected_unit = rendered_row.at_css("select[name$='[quantity_unit_code]'] option[selected]")

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(rendered_row.at_css("input[name$='[price]']")['value']).to eq('141')
      expect(rendered_row.at_css("input[name$='[quantity]']")['value']).to eq('0')
      expect(selected_unit['value']).to eq('milliliter')
      expect(rendered_row.at_css("input[name$='[original_line_total]']")['value']).to eq('1200')
      expect(rendered_row.at_css("input[name$='[line_total]']")['value']).to eq('1200')
      expect(response.body).to include(I18n.t('errors.messages.greater_than', count: 0))
      expect(persisted_amount_snapshot(receipt, item)).to eq(persisted_before)
      expect(receipt.lock_version).to eq(lock_version_before)
    end
  end

  it 'JSが空hidden小計を0へ同期した手動measurementを0円で保存する' do
    post receipts_path, params: {
      receipt: {
        store_name: '手動計量0円店',
        payment_method: 'cash',
        receipt_items_attributes: {
          '0' => {
            confirmed_name: '手動計量商品',
            price: '140',
            quantity: '8.12',
            quantity_unit_code: 'liter',
            tax_rate: '0',
            original_line_total: '0',
            line_total: '0'
          }
        }
      }
    }

    receipt = user.receipts.find_by!(store_name: '手動計量0円店')
    item = receipt.receipt_items.first

    aggregate_failures do
      expect(response).to redirect_to(receipts_path)
      expect(receipt).to have_attributes(
        subtotal_amount: 0,
        tax_amount: 0,
        total_amount: 0,
        status: 'completed'
      )
      expect(item).to have_attributes(
        price: 140,
        quantity: BigDecimal('8.12'),
        quantity_unit_code: 'liter',
        original_line_total: 0,
        line_total: 0
      )
    end
  end

  it 'JSを通さない空hidden小計の手動measurementを保存しない' do
    expect do
      post receipts_path, params: {
        receipt: {
          store_name: '手動計量空欄店',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '手動計量空欄商品',
              price: '140',
              quantity: '8.12',
              quantity_unit_code: 'liter',
              tax_rate: '0',
              original_line_total: '',
              line_total: ''
            }
          }
        }
      }
    end.not_to change(Receipt, :count)

    document = Nokogiri::HTML(response.body)
    rendered_row = rendered_item_row(document, item_name: '手動計量空欄商品')
    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('receipts.form.errors.item_amount_required'))
      expect(rendered_row.at_css("input[name$='[price]']")['value']).to eq('140')
    end
  end
end
