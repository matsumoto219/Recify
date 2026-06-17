require 'rails_helper'

RSpec.describe 'Home', type: :request do
  describe 'GET /' do
    it '未ログイン時はhome#indexを表示する' do
      get root_path

      document = Nokogiri::HTML(response.body)
      public_header = document.at_css('#public-header')
      public_footer = document.at_css('#public-footer')
      sign_up_link = public_header.at_css("a[href='#{new_user_registration_path}']")

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Home#index')
        expect(response.body).to include('Find me in app/views/home/index.html.erb')
        expect(public_header).to be_present
        expect(public_header.at_css('.brand-logo-full[aria-label="Recify"]')).to be_present
        expect(public_header.at_css("a[href='#{new_user_session_path}']")).to be_present
        expect(sign_up_link).to be_present
        expect(sign_up_link['class']).to include('btn-primary')
        expect(public_footer).to be_present
        expect(public_footer.at_css('.brand-logo-compact[aria-label="Recify"]')).to be_present
        expect(public_footer.at_css("a[href='#{contact_path}']")).to be_present
        expect(public_footer.at_css("a[href='#{terms_path}']")).to be_present
        expect(public_footer.at_css("a[href='#{privacy_path}']")).to be_present
        expect(response.body).not_to include('href="#"')
        expect(response.body).not_to include('translation missing')
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
