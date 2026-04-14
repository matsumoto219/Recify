require 'rails_helper'

RSpec.describe 'Receipts', type: :request do
  let(:user) { create(:user) }
  let(:image_path) { Rails.root.join('spec/fixtures/files/receipt_sample.jpg') }
  let(:uploaded_image) do
    Rack::Test::UploadedFile.new(image_path, 'image/jpeg')
  end

  before do
    sign_in user
    allow(Analysis::ReceiptProcessingErrorMapper).to receive(:map).and_return({ error_category: 'ocr_error' })
  end

  describe 'GET /receipts' do
    let!(:my_receipt) do
      create(:receipt, user: user, store_name: '自分のレシート', total_amount: 1000, payment_method: 'cash', status: 'completed')
    end
    let!(:other_receipt) do
      other_user = create(:user, email: 'index_other@example.com')
      create(:receipt, user: other_user, store_name: '他人のレシート', total_amount: 999, payment_method: 'cash', status: 'completed')
    end

    it '一覧を取得できる' do
      get receipts_path

      expect(response).to have_http_status(:success)
    end

    it '自分のレシートだけが表示される' do
      get receipts_path

      aggregate_failures do
        expect(response.body).to include('自分のレシート')
        expect(response.body).not_to include('他人のレシート')
      end
    end

    context '未ログイン時' do
      before do
        sign_out user
      end

      it 'ログイン画面へリダイレクトされる' do
        get receipts_path

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe 'GET /receipts/new' do
    it '新規作成画面を取得できる' do
      get new_receipt_path

      expect(response).to have_http_status(:success)
    end

    it '手動登録モードでも画面を取得できる' do
      get new_receipt_path, params: { mode: 'manual' }

      expect(response).to have_http_status(:success)
    end

    context '未ログイン時' do
      before do
        sign_out user
      end

      it 'ログイン画面へリダイレクトされる' do
        get new_receipt_path

        expect(response).to redirect_to(new_user_session_path)
      end
    end
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
      expect(Receipt.order(:id).last.status).to eq('uploaded')
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

    it '画像なし作成時にstatusが入る' do
      post receipts_path, params: valid_params

      receipt = Receipt.order(:id).last
      expect(receipt.status).to eq('uploaded')
    end

    it '画像あり作成時はprocessingで保存される' do
      allow(ReceiptAnalysisService).to receive(:call)

      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '画像付きレシート',
            total_amount: 1500,
            payment_method: 'cash',
            image: uploaded_image
          }
        }
      end.to change(Receipt, :count).by(1)

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(receipt.status).to eq('processing')
        expect(ReceiptAnalysisService).to have_received(:call).with(receipt)
        expect(response).to redirect_to(receipts_path)
      end
    end

    it '画像ありで解析失敗時は一覧へ戻る' do
      allow(ReceiptAnalysisService).to receive(:call) do |receipt|
        receipt.update!(
          status: 'failed',
          processing_error_code: 'ocr_unreadable',
          processing_error_message: 'dummy error'
        )
      end

      post receipts_path, params: {
        receipt: {
          store_name: '解析失敗レシート',
          total_amount: 1800,
          payment_method: 'cash',
          image: uploaded_image
        }
      }

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.status).to eq('failed')
        expect(ReceiptAnalysisService).to have_received(:call).with(receipt)
        expect(receipt.processing_error_code).to eq('ocr_unreadable')
      end
    end

    it '画像なし作成時は解析を実行しない' do
      allow(ReceiptAnalysisService).to receive(:call)

      post receipts_path, params: valid_params

      expect(ReceiptAnalysisService).not_to have_received(:call)
    end

    it '不正なパラメータでは作成できない' do
      expect do
        post receipts_path, params: invalid_params
      end.not_to change(Receipt, :count)

      expect([ 200, 422 ]).to include(response.status)
    end

    it '対応外形式の画像では作成できない' do
      invalid_file = Rack::Test::UploadedFile.new(
        Tempfile.create([ 'invalid', '.txt' ]).tap { |f| f.write('dummy'); f.rewind }.path,
        'text/plain'
      )

      # Prevent image_tag error in view
      allow_any_instance_of(ActionView::Base).to receive(:image_tag).and_return('')
      # Also stub error mapper locally for safety
      allow(Analysis::ReceiptProcessingErrorMapper).to receive(:map).and_return({ error_category: 'ocr_error' })

      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '不正画像',
            total_amount: 1000,
            payment_method: 'cash',
            image: invalid_file
          }
        }
      end.not_to change(Receipt, :count)

      expect([ 200, 422 ]).to include(response.status)
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

  describe 'GET /receipts/:id/edit' do
    let(:receipt) do
      create(:receipt, user: user, store_name: '編集対象', total_amount: 1300, payment_method: 'cash', status: 'review_needed')
    end

    it '編集画面を取得できる' do
      get edit_receipt_path(receipt)

      expect(response).to have_http_status(:success)
    end

    it '他人のレシート編集画面は取得できない' do
      other_user = create(:user, email: 'edit_other@example.com')
      other_receipt = create(:receipt, user: other_user, store_name: '他人編集', total_amount: 900, payment_method: 'cash', status: 'completed')

      get edit_receipt_path(other_receipt)

      expect(response).to have_http_status(:not_found)
    end

    context '未ログイン時' do
      before do
        sign_out user
      end

      it 'ログイン画面へリダイレクトされる' do
        get edit_receipt_path(receipt)

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe 'PATCH /receipts/:id' do
    let(:receipt) do
      create(
        :receipt,
        user: user,
        store_name: '更新前',
        total_amount: 1400,
        payment_method: 'cash',
        status: 'review_needed'
      )
    end

    let(:valid_update_params) do
      {
        receipt: {
          store_name: '更新後',
          total_amount: 2000,
          payment_method: 'credit_card',
          memo: '更新メモ'
        }
      }
    end

    let(:invalid_update_params) do
      {
        receipt: {
          store_name: '',
          total_amount: nil,
          payment_method: 'cash'
        }
      }
    end

    it 'レシートを更新できる' do
      patch receipt_path(receipt), params: valid_update_params
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.store_name).to eq('更新後')
        expect(receipt.total_amount).to eq(2000)
        expect(receipt.payment_method).to eq('credit_card')
        expect(receipt.memo).to eq('更新メモ')
      end
    end

    it '不正なパラメータでは更新できない' do
      patch receipt_path(receipt), params: invalid_update_params
      receipt.reload

      aggregate_failures do
        expect([ 200, 422 ]).to include(response.status)
        expect(receipt.store_name).to eq('更新前')
        expect(receipt.total_amount).to eq(1400)
      end
    end

    it '画像差し替え時はprocessingにして再解析へ進む' do
      allow(ReceiptAnalysisService).to receive(:call)

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '画像差し替え後',
          total_amount: 2100,
          payment_method: 'cash',
          image: uploaded_image
        }
      }
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('processing')
        expect(ReceiptAnalysisService).to have_received(:call).with(receipt)
      end
    end

    it '画像差し替えで解析失敗時は詳細へ戻る' do
      allow(ReceiptAnalysisService).to receive(:call) do |target_receipt|
        target_receipt.update!(
          status: 'failed',
          processing_error_code: 'ocr_unreadable',
          processing_error_message: 'dummy error'
        )
      end

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '画像差し替え失敗',
          total_amount: 2200,
          payment_method: 'cash',
          image: uploaded_image
        }
      }
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('failed')
        expect(ReceiptAnalysisService).to have_received(:call).with(receipt)
        expect(receipt.processing_error_code).to eq('ocr_unreadable')
      end
    end

    it '画像差し替えなし更新時は再解析を実行しない' do
      allow(ReceiptAnalysisService).to receive(:call)

      patch receipt_path(receipt), params: valid_update_params
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('review_needed')
        expect(ReceiptAnalysisService).not_to have_received(:call)
      end
    end

    it '他人のレシートは更新できない' do
      other_user = create(:user, email: 'update_other@example.com')
      other_receipt = create(:receipt, user: other_user, store_name: '他人更新前', total_amount: 800, payment_method: 'cash', status: 'completed')

      patch receipt_path(other_receipt), params: valid_update_params

      expect(response).to have_http_status(:not_found)
    end

    context '未ログイン時' do
      before do
        sign_out user
      end

      it 'ログイン画面へリダイレクトされる' do
        patch receipt_path(receipt), params: valid_update_params

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe 'DELETE /receipts/:id' do
    let!(:receipt) do
      create(:receipt, user: user, store_name: '削除対象', total_amount: 1500, payment_method: 'cash', status: 'completed')
    end

    it 'レシートを削除できる' do
      expect do
        delete receipt_path(receipt)
      end.to change(Receipt, :count).by(-1)

      expect(response).to redirect_to(receipts_path)
    end

    it '他人のレシートは削除できない' do
      other_user = create(:user, email: 'destroy_other@example.com')
      other_receipt = create(:receipt, user: other_user, store_name: '他人削除', total_amount: 700, payment_method: 'cash', status: 'completed')

      expect do
        delete receipt_path(other_receipt)
      end.not_to change(Receipt, :count)

      expect(response).to have_http_status(:not_found)
    end

    context '未ログイン時' do
      before do
        sign_out user
      end

      it 'ログイン画面へリダイレクトされる' do
        delete receipt_path(receipt)

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end
end
