require 'rails_helper'

RSpec.describe 'Receipt manual core validation', type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  def uploaded_image
    Rack::Test::UploadedFile.new(
      Rails.root.join('spec/fixtures/files/receipt_sample.jpg'),
      'image/jpeg'
    )
  end

  def amountless_item_attributes
    {
      '0' => {
        confirmed_name: '金額未入力商品',
        price: '',
        quantity: '1',
        quantity_unit_code: 'each',
        line_total: ''
      }
    }
  end

  def payment_attributes
    {
      '0' => {
        method: '現金',
        amount: '50'
      }
    }
  end

  def store_name_blank_error_message
    I18n.t(
      'errors.format',
      attribute: Receipt.human_attribute_name(:store_name),
      message: I18n.t('errors.messages.blank')
    )
  end

  it '画像と別の確認理由があっても店舗名・合計金額が空の手動作成を拒否する' do
    create(:usage_counter, user: user, key: 'manual_receipts_per_day', used_count: 7)

    expect do
      post receipts_path, params: {
        receipt: {
          image: uploaded_image,
          store_name: '',
          total_amount: '',
          payment_method: 'cash',
          receipt_items_attributes: amountless_item_attributes,
          receipt_payments_attributes: payment_attributes
        }
      }
    end.not_to change(Receipt, :count)

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(store_name_blank_error_message)
      expect(response.body).to include(I18n.t('receipts.form.errors.item_amount_required'))
      expect(UsageCounter.find_by!(user: user, key: 'manual_receipts_per_day').used_count).to eq(7)
    end
  end

  it '店舗名・合計金額が揃った画像付き要確認データは手動作成できる' do
    expect do
      post receipts_path, params: {
        receipt: {
          image: uploaded_image,
          store_name: '画像付き要確認店舗',
          total_amount: '100',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '課税商品',
              price: '100',
              quantity: '1',
              quantity_unit_code: 'each',
              tax_rate: '10',
              line_total: '100'
            }
          }
        }
      }
    end.to change(Receipt, :count).by(1)

    receipt = Receipt.order(:id).last

    aggregate_failures do
      expect(response).to redirect_to(receipts_path)
      expect(receipt).to be_review_needed
      expect(receipt.review_reasons).to include('invalid_amount_relation')
    end
  end

  it '画像付き要確認データの入力済み店舗名を空へ戻す更新を拒否する' do
    receipt = create(
      :receipt,
      :review_needed,
      :with_image,
      user: user,
      store_name: '変更前店舗',
      subtotal_amount: 100,
      tax_amount: 0,
      total_amount: 100,
      review_reasons: [ 'payment_amount_mismatch' ]
    )
    receipt.receipt_items.create!(
      confirmed_name: '商品',
      price: 100,
      quantity: 1,
      quantity_unit_code: 'each',
      line_total: 100,
      needs_review: false
    )
    receipt.receipt_payments.create!(method: '現金', amount: 50)

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        store_name: ''
      }
    }

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(store_name_blank_error_message)
      expect(Receipt.find(receipt.id).store_name).to eq('変更前店舗')
    end
  end

  it '画像付き要確認データの既存店舗名が空のままならメモだけ更新できる' do
    receipt = create(
      :receipt,
      :review_needed,
      :with_image,
      user: user,
      store_name: nil,
      subtotal_amount: 100,
      tax_amount: 0,
      total_amount: 100,
      review_reasons: [ 'store_name_missing' ]
    )
    receipt.receipt_items.create!(
      confirmed_name: '商品',
      price: 100,
      quantity: 1,
      quantity_unit_code: 'each',
      line_total: 100,
      needs_review: false
    )

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        memo: '部分データのメモ更新'
      }
    }

    receipt.reload

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.store_name).to be_nil
      expect(receipt.memo).to eq('部分データのメモ更新')
    end
  end
end
