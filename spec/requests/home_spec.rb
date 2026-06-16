require 'rails_helper'

RSpec.describe 'Home', type: :request do
  describe 'GET /' do
    it '未ログイン時はhome#indexを表示する' do
      get root_path

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Home#index')
        expect(response.body).to include('Find me in app/views/home/index.html.erb')
      end
    end

    it 'ログイン済みならレシート一覧へリダイレクトする' do
      user = create(:user)
      sign_in user

      get root_path

      aggregate_failures do
        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(receipts_path)
      end

      follow_redirect!

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(request.path).to eq(receipts_path)
        expect(request.path).not_to eq(root_path)
      end
    end
  end
end
