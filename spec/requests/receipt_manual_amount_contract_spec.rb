require 'rails_helper'

RSpec.describe 'Receipt manual amount contract', type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  def manual_item_attributes
    {
      '0' => {
        confirmed_name: '課税商品',
        price: '100',
        quantity: '1',
        quantity_unit_code: 'each',
        tax_rate: '10',
        line_total: '100'
      }
    }
  end

  it 'total-only入力でも課税明細から税額を再計算してreview_neededにする' do
    post receipts_path, params: {
      receipt: {
        store_name: '手動金額契約店',
        payment_method: 'cash',
        total_amount: '100',
        receipt_items_attributes: manual_item_attributes
      }
    }

    receipt = Receipt.order(:id).last

    aggregate_failures do
      expect(response).to redirect_to(receipts_path)
      expect(receipt.status).to eq('review_needed')
      expect(receipt.subtotal_amount).to eq(91)
      expect(receipt.tax_amount).to eq(9)
      expect(receipt.total_amount).to eq(100)
      expect(receipt.review_reasons).to include('invalid_amount_relation')
    end
  end

  it '不整合なsubtotal tax totalをcompletedで保存しない' do
    post receipts_path, params: {
      receipt: {
        store_name: '手動不整合入力店',
        payment_method: 'cash',
        subtotal_amount: '100',
        tax_amount: '100',
        total_amount: '100',
        receipt_items_attributes: manual_item_attributes
      }
    }

    receipt = Receipt.order(:id).last

    aggregate_failures do
      expect(response).to redirect_to(receipts_path)
      expect(receipt.status).to eq('review_needed')
      expect(receipt.subtotal_amount).to eq(91)
      expect(receipt.tax_amount).to eq(9)
      expect(receipt.total_amount).to eq(100)
      expect(receipt.review_reasons).to include('invalid_amount_relation')
    end
  end

  it '購入合計を超えるcouponを保存しない' do
    expect do
      post receipts_path, params: {
        receipt: {
          store_name: '過大クーポン入力店',
          payment_method: 'cash',
          receipt_items_attributes: manual_item_attributes,
          receipt_adjustments_attributes: {
            '0' => {
              kind: 'coupon',
              label: 'クーポン',
              amount: '200',
              sign: 'discount',
              tax_rate: '0'
            }
          }
        }
      }
    end.not_to change(Receipt, :count)

    expect(response).to have_http_status(:unprocessable_content)
  end

  it '購入合計を超えるpoint usageをreview_neededで保存する' do
    post receipts_path, params: {
      receipt: {
        store_name: '過大ポイント入力店',
        payment_method: 'e_money',
        receipt_items_attributes: manual_item_attributes,
        receipt_adjustments_attributes: {
          '0' => {
            kind: 'point_usage',
            label: 'ポイント利用',
            amount: '200',
            sign: 'discount',
            tax_rate: ''
          }
        }
      }
    }

    receipt = Receipt.order(:id).last

    aggregate_failures do
      expect(receipt.status).to eq('review_needed')
      expect(receipt.total_amount).to eq(100)
      expect(receipt.amount_calculation_profile.dig('computed', 'final_payment_total')).to eq(-100)
      expect(receipt.review_reasons).to include('invalid_amount_relation')
    end
  end
end
