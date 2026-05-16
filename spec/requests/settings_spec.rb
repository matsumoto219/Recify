require 'rails_helper'

RSpec.describe 'Settings', type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  describe 'GET /settings' do
    it 'shows receipt item delete confirmation toggle' do
      get settings_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('明細削除の確認')
        expect(response.body).to include('レシート明細を削除する前に確認ダイアログを表示します')
        expect(document.at_css('input[name="receipt_item_delete_confirmation_enabled"]')).to be_present
      end
    end
  end

  describe 'PATCH /settings' do
    it 'Turbo Streamでflash targetを更新する' do
      patch settings_path,
            params: { user: { theme_preference: 'dark' } },
            headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' }

      document = Nokogiri::HTML(response.body)
      stream = document.at_css('turbo-stream[target="flash"]')
      notice_surface = stream.at_css('[data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.media_type).to eq('text/vnd.turbo-stream.html')
        expect(stream).to be_present
        expect(stream['action']).to eq('update')
        expect(notice_surface).to be_present
        expect(notice_surface['data-notice-surface-auto-dismiss-value']).to eq('true')
      end
    end

    it 'updates receipt item delete confirmation setting to false' do
      patch settings_path,
            params: { user: { receipt_item_delete_confirmation_enabled: false } },
            as: :json

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(user.reload.receipt_item_delete_confirmation_enabled).to be(false)
        expect(response.parsed_body).to include(
          'ok' => true,
          'receipt_item_delete_confirmation_enabled' => false
        )
      end
    end

    it 'updates receipt item delete confirmation setting to true' do
      user.update!(receipt_item_delete_confirmation_enabled: false)

      patch settings_path,
            params: { user: { receipt_item_delete_confirmation_enabled: true } },
            as: :json

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(user.reload.receipt_item_delete_confirmation_enabled).to be(true)
        expect(response.parsed_body).to include(
          'ok' => true,
          'receipt_item_delete_confirmation_enabled' => true
        )
      end
    end
  end
end
