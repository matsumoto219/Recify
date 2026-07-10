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
end
