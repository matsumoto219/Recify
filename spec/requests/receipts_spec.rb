require 'rails_helper'

RSpec.describe 'Receipts', type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  describe 'POST /receipts' do
    let(:valid_params) do
      {
        receipt: {
          store_name: 'テスト',
          total_amount: 1000,
          payment_method: 'cash',
          status: 'uploaded'
        }
      }
    end

    let(:invalid_params) do
      {
        receipt: {
          store_name: '',
          total_amount: nil,
          payment_method: 'cash',
          status: 'uploaded'
        }
      }
    end

    it 'レシートを作成できる' do
      expect do
        post receipts_path, params: valid_params
      end.to change(Receipt, :count).by(1)

      expect(response).to have_http_status(:redirect)
    end

    it 'ログインユーザーに紐づいて作成される' do
      post receipts_path, params: valid_params

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(receipt.user).to eq(user)
        expect(receipt.store_name).to eq('テスト')
        expect(receipt.total_amount).to eq(1000)
      end
    end

    it '作成時にstatusが入る' do
      post receipts_path, params: valid_params

      receipt = Receipt.order(:id).last
      expect(receipt.status).to be_present
    end

    it '不正なパラメータでは作成できない' do
      expect do
        post receipts_path, params: invalid_params
      end.not_to change(Receipt, :count)

      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:ok)
    end

    context '未ログイン時' do
      before do
        sign_out user
      end

      it 'ログイン画面へリダイレクトされる' do
        post receipts_path, params: valid_params

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe 'GET /receipts/:id' do
    let(:receipt) do
      create(
        :receipt,
        user: user,
        store_name: 'テスト店',
        total_amount: 1200,
        payment_method: 'cash',
        status: 'completed'
      )
    end

    it '詳細を取得できる' do
      get receipt_path(receipt)

      expect(response).to have_http_status(:success)
    end

    it 'レスポンスにレシート情報が含まれる' do
      get receipt_path(receipt)

      expect(response.body).to include('テスト店')
    end

    it '他人のレシートは取得できない' do
      other_user = create(:user, email: 'other@example.com')
      other_receipt = create(
        :receipt,
        user: other_user,
        store_name: '他人のレシート',
        total_amount: 999,
        payment_method: 'cash',
        status: 'completed'
      )

      get receipt_path(other_receipt)

      expect(response).to have_http_status(:not_found)
    end

    context '未ログイン時' do
      before do
        sign_out user
      end

      it 'ログイン画面へリダイレクトされる' do
        get receipt_path(receipt)

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end
end
