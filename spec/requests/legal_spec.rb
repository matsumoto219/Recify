require 'rails_helper'

RSpec.describe 'Legal pages', type: :request do
  describe 'GET /terms' do
    it '未ログインで利用規約shellを表示する' do
      expect(terms_path).to eq('/terms')

      get terms_path

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('legal.terms.title'))
        expect(response.body).to include(I18n.t('legal.common.placeholder_title'))
        expect(response.body).to include(I18n.t('legal.common.placeholder_body'))
        expect(response.body).to include(I18n.t('legal.common.last_updated', date: I18n.t('legal.terms.last_updated_on')))
        expect(response.body).not_to include('translation missing')
      end
    end

    it 'ログイン済みでもレシート一覧へリダイレクトせずpublic layoutで表示する' do
      sign_in create(:user)

      get terms_path

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response).not_to redirect_to(receipts_path)
        expect(response.body).to include(I18n.t('legal.terms.title'))
        expect(response.body).not_to include('id="desktop-sidebar"')
        expect(response.body).not_to include('translation missing')
      end
    end
  end

  describe 'GET /privacy' do
    it '未ログインでプライバシーポリシーshellを表示する' do
      expect(privacy_path).to eq('/privacy')

      get privacy_path

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('legal.privacy.title'))
        expect(response.body).to include(I18n.t('legal.common.placeholder_title'))
        expect(response.body).to include(I18n.t('legal.common.placeholder_body'))
        expect(response.body).to include(I18n.t('legal.common.last_updated', date: I18n.t('legal.privacy.last_updated_on')))
        expect(response.body).not_to include('translation missing')
      end
    end

    it 'ログイン済みでもレシート一覧へリダイレクトせずpublic layoutで表示する' do
      sign_in create(:user)

      get privacy_path

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response).not_to redirect_to(receipts_path)
        expect(response.body).to include(I18n.t('legal.privacy.title'))
        expect(response.body).not_to include('id="desktop-sidebar"')
        expect(response.body).not_to include('translation missing')
      end
    end
  end
end
