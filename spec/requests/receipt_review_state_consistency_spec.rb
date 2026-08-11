require 'rails_helper'

RSpec.describe 'Receipt manual edit review state', type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  def create_receipt(attributes = {})
    receipt = create(
      :receipt,
      user: user,
      store_name: '確認対象店舗',
      subtotal_amount: 91,
      tax_amount: 9,
      total_amount: 100,
      status: 'completed',
      **attributes
    )
    receipt.receipt_items.create!(
      confirmed_name: '確認対象商品',
      price: 100,
      quantity: 1,
      quantity_unit_code: 'each',
      tax_rate: BigDecimal('0.1'),
      line_total: 100,
      needs_review: false,
      review_reasons: []
    )
    receipt
  end

  def patch_receipt(receipt, attributes)
    patch receipt_path(receipt), params: {
      receipt: { lock_version: receipt.lock_version }.merge(attributes)
    }
  end

  def item_attributes(item, overrides = {})
    {
      id: item.id,
      confirmed_name: item.confirmed_name,
      category: item.category,
      price: item.price,
      quantity: item.quantity.to_s,
      quantity_unit_code: item.quantity_unit_code,
      product_code: item.product_code,
      tax_rate: item.tax_rate.to_d * 100,
      line_total: item.line_total,
      position_index: item.position_index,
      _destroy: '0'
    }.merge(overrides)
  end

  it '手動作成時のblank購入日時・支払方法は通常のitem編集後もcompletedのまま維持する' do
    post receipts_path, params: {
      receipt: {
        store_name: '手動作成店舗',
        total_amount: 100,
        payment_method: '',
        receipt_items_attributes: {
          '0' => {
            confirmed_name: '手動作成商品',
            price: 100,
            quantity: 1,
            quantity_unit_code: 'each',
            line_total: 100
          }
        }
      }
    }
    receipt = Receipt.order(:id).last

    aggregate_failures 'manual create' do
      expect(response).to redirect_to(receipts_path)
      expect(receipt.purchased_at).to be_nil
      expect(receipt.payment_method).to be_nil
      expect(receipt.review_reasons).to be_empty
      expect(receipt.status).to eq('completed')
    end

    item = receipt.receipt_items.sole
    patch_receipt(
      receipt,
      receipt_items_attributes: {
        '0' => item_attributes(item, quantity_unit_code: 'piece')
      }
    )
    receipt.reload

    aggregate_failures 'item edit' do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(item.reload.quantity_unit_code).to eq('piece')
      expect(receipt.purchased_at).to be_nil
      expect(receipt.payment_method).to be_nil
      expect(receipt.review_reasons).to be_empty
      expect(receipt.status).to eq('completed')
    end
  end

  it '住所だけの更新でもreview stateを再構築し、他のblank fieldからmissing reasonを合成しない' do
    receipt = create_receipt(
      store_address: '変更前住所',
      purchased_at: nil,
      payment_method: nil,
      status: 'review_needed',
      review_reasons: [ 'store_address_uncertain' ]
    )

    patch_receipt(receipt, store_address: '変更後住所')
    receipt.reload

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.store_address).to eq('変更後住所')
      expect(receipt.review_reasons).to be_empty
      expect(receipt.status).to eq('completed')
    end
  end

  it '購入日時だけの更新でも既存missing reasonを解除する' do
    receipt = create_receipt(
      purchased_at: nil,
      payment_method: nil,
      status: 'review_needed',
      review_reasons: [ 'purchased_at_missing' ]
    )

    patch_receipt(receipt, purchased_on: '2026-07-01', purchased_time: '12:00')
    receipt.reload

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.purchased_at).to eq(Time.zone.local(2026, 7, 1, 12, 0))
      expect(receipt.review_reasons).to be_empty
      expect(receipt.status).to eq('completed')
    end
  end

  it 'warning-only reasonはcore field更新後も保持し、completedへ正規化する' do
    receipt = create_receipt(
      status: 'review_needed',
      review_reasons: [ 'ocr_low_confidence' ]
    )

    patch_receipt(receipt, store_name: '変更後店舗')
    receipt.reload

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.review_reasons).to eq([ 'ocr_low_confidence' ])
      expect(receipt.status).to eq('completed')
    end
  end

  it 'warning-only itemは通常のitem再送信でneeds_reviewへ昇格させない' do
    receipt = create_receipt(
      status: 'completed',
      review_reasons: [ 'item_tax_rate_uncertain' ]
    )
    item = receipt.receipt_items.sole
    item.update!(
      needs_review: false,
      review_reasons: [ 'item_tax_rate_uncertain' ]
    )

    patch_receipt(
      receipt,
      receipt_items_attributes: {
        '0' => item_attributes(item)
      }
    )
    receipt.reload
    item.reload

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(item.review_reasons).to eq([ 'item_tax_rate_uncertain' ])
      expect(item.needs_review).to be(false)
      expect(receipt.review_reasons).to eq([ 'item_tax_rate_uncertain' ])
      expect(receipt.status).to eq('completed')
    end
  end

  it 'processing errorを持つfailed receiptのmemoだけを更新してもblocking reasonを保持する' do
    receipt = create_receipt(
      status: 'failed',
      review_reasons: [ 'ocr_unreadable' ],
      processing_error_code: 'ocr_api_error',
      processing_error_message: 'safe error'
    )

    patch_receipt(receipt, memo: '確認済みメモ')
    receipt.reload

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.memo).to eq('確認済みメモ')
      expect(receipt.processing_error_code).to be_nil
      expect(receipt.processing_error_message).to be_nil
      expect(receipt.review_reasons).to eq([ 'ocr_unreadable' ])
      expect(receipt.status).to eq('review_needed')
    end
  end

  it 'fallback errorだけが要確認の説明である場合はfull form保存後も案内を保持する' do
    receipt = create_receipt(
      status: 'review_needed',
      review_reasons: [],
      processing_error_code: 'ai_unavailable',
      processing_error_message: 'safe fallback guidance'
    )

    item = receipt.receipt_items.sole
    patch_receipt(
      receipt,
      memo: '確認済みメモ',
      store_name: receipt.store_name,
      subtotal_amount: receipt.subtotal_amount,
      tax_amount: receipt.tax_amount,
      total_amount: receipt.total_amount,
      payment_method: receipt.payment_method,
      receipt_items_attributes: {
        '0' => item_attributes(item)
      }
    )
    receipt.reload

    aggregate_failures 'persisted state' do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.memo).to eq('確認済みメモ')
      expect(receipt.status).to eq('review_needed')
      expect(receipt.review_reasons).to be_empty
      expect(receipt.processing_error_code).to eq('ai_unavailable')
      expect(receipt.processing_error_message).to eq('safe fallback guidance')
    end

    get receipt_path(receipt)

    aggregate_failures 'visible explanation' do
      expect(response).to have_http_status(:success)
      expect(response.body).to include(I18n.t('receipts.processing_error_card.attention_title'))
      expect(response.body).to include(I18n.t('receipts.processing_error_codes.ai_unavailable'))
    end
  end

  it 'review reasonのないfailed receiptはmemoだけの更新でprocessing errorを解除してcompletedにする' do
    receipt = create_receipt(
      status: 'failed',
      review_reasons: [],
      processing_error_code: 'ocr_api_error',
      processing_error_message: 'safe error'
    )

    patch_receipt(receipt, memo: '確認済みメモ')
    receipt.reload

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.memo).to eq('確認済みメモ')
      expect(receipt.processing_error_code).to be_nil
      expect(receipt.processing_error_message).to be_nil
      expect(receipt.review_reasons).to be_empty
      expect(receipt.status).to eq('completed')
    end
  end

  it '異なる明示reasonを持つ明細は修正した明細だけを確認済みにする' do
    receipt = create_receipt(
      subtotal_amount: 182,
      tax_amount: 18,
      total_amount: 200,
      status: 'review_needed',
      review_reasons: %w[item_name_uncertain item_category_uncertain]
    )
    name_item = receipt.receipt_items.sole
    name_item.update!(
      needs_review: true,
      review_reasons: [ 'item_name_uncertain' ]
    )
    category_item = receipt.receipt_items.create!(
      confirmed_name: 'カテゴリ確認商品',
      category: 'other',
      price: 100,
      quantity: 1,
      quantity_unit_code: 'each',
      tax_rate: BigDecimal('0.1'),
      line_total: 100,
      position_index: 1,
      needs_review: true,
      review_reasons: [ 'item_category_uncertain' ]
    )

    patch_receipt(
      receipt,
      receipt_items_attributes: {
        '0' => item_attributes(name_item, confirmed_name: '確認済み商品'),
        '1' => item_attributes(category_item)
      }
    )
    receipt.reload

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(name_item.reload).to have_attributes(
        confirmed_name: '確認済み商品',
        needs_review: false,
        review_reasons: []
      )
      expect(category_item.reload).to have_attributes(
        needs_review: true,
        review_reasons: [ 'item_category_uncertain' ]
      )
      expect(receipt.review_reasons).to eq([ 'item_category_uncertain' ])
      expect(receipt.status).to eq('review_needed')
    end
  end

  it 'full form相当で同じcore fieldを再送信してもuncertain/conflicted reasonを保持する' do
    purchased_at = Time.zone.local(2026, 7, 1, 12, 0)
    receipt = create_receipt(
      store_name: '確認中店舗',
      store_address: '確認中住所',
      store_phone_number: '03-0000-0000',
      purchased_at: purchased_at,
      payment_method: 'cash',
      status: 'review_needed',
      review_reasons: %w[
        store_name_uncertain
        store_address_uncertain
        store_phone_number_uncertain
        purchased_at_uncertain
        purchased_at_conflicted
        payment_method_uncertain
      ]
    )
    item = receipt.receipt_items.sole

    patch_receipt(
      receipt,
      store_name: receipt.store_name,
      store_address: receipt.store_address,
      store_phone_number: receipt.display_store_phone_number,
      purchased_on: purchased_at.to_date.iso8601,
      purchased_time: purchased_at.strftime('%H:%M'),
      payment_method: receipt.payment_method,
      subtotal_amount: receipt.subtotal_amount,
      tax_amount: receipt.tax_amount,
      total_amount: receipt.total_amount,
      receipt_items_attributes: {
        '0' => item_attributes(item)
      }
    )
    receipt.reload

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.review_reasons).to contain_exactly(
        'store_name_uncertain',
        'store_address_uncertain',
        'store_phone_number_uncertain',
        'purchased_at_uncertain',
        'purchased_at_conflicted',
        'payment_method_uncertain'
      )
      expect(receipt.status).to eq('review_needed')
    end
  end
end
