require 'rails_helper'

RSpec.describe 'Legal pages', type: :request do
  describe 'GET /terms' do
    it '未ログインで利用規約shellを表示する' do
      expect(terms_path).to eq('/terms')

      get terms_path
      document = Nokogiri::HTML(response.body)
      public_header = document.at_css('#public-header')
      public_footer = document.at_css('#public-footer')
      sign_up_link = public_header&.at_css("a[href='#{new_user_registration_path}']")

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('legal.terms.title'))
        expect(response.body).to include(I18n.t('legal.common.placeholder_title'))
        expect(response.body).to include(I18n.t('legal.common.placeholder_body'))
        expect(response.body).to include(I18n.t('legal.common.last_updated', date: I18n.t('legal.terms.last_updated_on')))
        expect(public_header).to be_present
        expect(public_header.at_css("a[href='#{new_user_session_path}']")).to be_present
        expect(sign_up_link).to be_present
        expect(sign_up_link['class']).to include('btn-primary')
        expect(public_footer).to be_present
        expect(public_footer.at_css("a[href='#{contact_path}']")).to be_present
        expect(public_footer.at_css("a[href='#{terms_path}']")).to be_present
        expect(public_footer.at_css("a[href='#{privacy_path}']")).to be_present
        expect(response.body).not_to include('/home_lp.css')
        expect(response.body).not_to include('data-controller="home-reveal"')
        expect(response.body).not_to include('href="#"')
        expect(response.body).not_to include('translation missing')
      end
    end

    it 'ログイン済みでもレシート一覧へリダイレクトせずpublic layoutで表示する' do
      sign_in create(:user)

      get terms_path
      document = Nokogiri::HTML(response.body)
      public_header = document.at_css('#public-header')
      receipts_link = public_header&.at_css("a[href='#{receipts_path}']")

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response).not_to redirect_to(receipts_path)
        expect(response.body).to include(I18n.t('legal.terms.title'))
        expect(public_header).to be_present
        expect(receipts_link).to be_present
        expect(receipts_link['class']).to include('btn-secondary')
        expect(public_header.at_css("a[href='#{new_user_session_path}']")).to be_nil
        expect(public_header.at_css("a[href='#{new_user_registration_path}']")).to be_nil
        expect(response.body).not_to include('/home_lp.css')
        expect(response.body).not_to include('data-controller="home-reveal"')
        expect(response.body).not_to include('id="desktop-sidebar"')
        expect(response.body).not_to include('translation missing')
      end
    end
  end

  describe 'GET /privacy' do
    it '未ログインでプライバシーポリシーshellを表示する' do
      expect(privacy_path).to eq('/privacy')

      get privacy_path
      document = Nokogiri::HTML(response.body)
      public_header = document.at_css('#public-header')
      public_footer = document.at_css('#public-footer')
      sign_up_link = public_header&.at_css("a[href='#{new_user_registration_path}']")

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('legal.privacy.title'))
        expect(response.body).to include(I18n.t('legal.common.placeholder_title'))
        expect(response.body).to include(I18n.t('legal.common.placeholder_body'))
        expect(response.body).to include(I18n.t('legal.common.last_updated', date: I18n.t('legal.privacy.last_updated_on')))
        expect(public_header).to be_present
        expect(public_header.at_css("a[href='#{new_user_session_path}']")).to be_present
        expect(sign_up_link).to be_present
        expect(sign_up_link['class']).to include('btn-primary')
        expect(public_footer).to be_present
        expect(public_footer.at_css("a[href='#{contact_path}']")).to be_present
        expect(public_footer.at_css("a[href='#{terms_path}']")).to be_present
        expect(public_footer.at_css("a[href='#{privacy_path}']")).to be_present
        expect(response.body).not_to include('/home_lp.css')
        expect(response.body).not_to include('data-controller="home-reveal"')
        expect(response.body).not_to include('href="#"')
        expect(response.body).not_to include('translation missing')
      end
    end

    it 'ログイン済みでもレシート一覧へリダイレクトせずpublic layoutで表示する' do
      sign_in create(:user)

      get privacy_path
      document = Nokogiri::HTML(response.body)
      public_header = document.at_css('#public-header')
      receipts_link = public_header&.at_css("a[href='#{receipts_path}']")

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response).not_to redirect_to(receipts_path)
        expect(response.body).to include(I18n.t('legal.privacy.title'))
        expect(public_header).to be_present
        expect(receipts_link).to be_present
        expect(receipts_link['class']).to include('btn-secondary')
        expect(public_header.at_css("a[href='#{new_user_session_path}']")).to be_nil
        expect(public_header.at_css("a[href='#{new_user_registration_path}']")).to be_nil
        expect(response.body).not_to include('/home_lp.css')
        expect(response.body).not_to include('data-controller="home-reveal"')
        expect(response.body).not_to include('id="desktop-sidebar"')
        expect(response.body).not_to include('translation missing')
      end
    end
  end
end
