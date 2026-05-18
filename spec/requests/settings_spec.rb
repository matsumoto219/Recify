require 'rails_helper'

RSpec.describe 'Settings', type: :request do
  let(:user) { create(:user) }
  let(:avatar_path) { Rails.root.join('spec/fixtures/files/receipt_sample.jpg') }
  let(:avatar_upload) { Rack::Test::UploadedFile.new(avatar_path, 'image/jpeg') }

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

    it 'header/settings index にfallback頭文字を表示する' do
      user.update!(name: 'Matsumoto')

      get settings_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.css('[data-avatar-fallback]').map(&:text)).to include('M')
      end
    end

    it 'attached avatar is rendered in header/settings index' do
      user.avatar.attach(avatar_upload)

      get settings_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.css('[data-avatar-image]')).to be_present
      end
    end

    it 'shared status badges use locale labels' do
      get settings_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('shared.service_status.ok'))
        expect(response.body).to include(I18n.t('shared.setting_status.inactive'))
      end
    end
  end

  describe 'GET /settings/account' do
    it 'avatar input and preview controller are present' do
      get settings_account_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('[data-controller~="avatar-preview"]')).to be_present
        expect(document.at_css('[data-controller~="avatar-preview"]')['data-avatar-preview-invalid-type-message-value']).to eq(I18n.t('settings.account.avatar.validation.invalid_type'))
        expect(document.at_css('[data-controller~="avatar-preview"]')['data-avatar-preview-file-too-large-message-value']).to eq(I18n.t('settings.account.avatar.validation.file_too_large'))
        expect(document.at_css('input[type="file"][name="user[avatar]"]')).to be_present
        expect(document.at_css('input[type="file"][name="user[avatar]"]')['accept']).to eq('image/png,image/jpeg,image/webp')
      end
    end
  end

  describe 'PATCH /users avatar' do
    it 'valid avatar upload attaches avatar' do
      patch user_registration_path,
            params: {
              update_context: 'account',
              user: {
                name: user.name,
                avatar: avatar_upload
              }
            }

      aggregate_failures do
        expect(response).to redirect_to(settings_path)
        expect(user.reload.avatar).to be_attached
      end
    end

    it 'invalid content type is rejected and not attached' do
      invalid_file = Tempfile.new([ 'avatar', '.txt' ])
      invalid_file.write('not an image')
      invalid_file.rewind

      patch user_registration_path,
            params: {
              update_context: 'account',
              user: {
                name: user.name,
                avatar: Rack::Test::UploadedFile.new(invalid_file.path, 'text/plain')
              }
            }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.avatar).not_to be_attached
        expect(response.body).to include('PNG/JPEG/WebP形式')
      end
    ensure
      invalid_file&.close
      invalid_file&.unlink
    end

    it 'files larger than 5MB are rejected and not attached' do
      large_file = Tempfile.new([ 'large-avatar', '.jpg' ])
      large_file.binmode
      large_file.write('0' * (5.megabytes + 1))
      large_file.rewind

      patch user_registration_path,
            params: {
              update_context: 'account',
              user: {
                name: user.name,
                avatar: Rack::Test::UploadedFile.new(large_file.path, 'image/jpeg')
              }
            }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.avatar).not_to be_attached
        expect(response.body).to include('5MB以下')
      end
    ensure
      large_file&.close
      large_file&.unlink
    end

    it 'remove_avatar=1 purges avatar' do
      user.avatar.attach(avatar_upload)
      expect(user.avatar).to be_attached

      patch user_registration_path,
            params: {
              update_context: 'account',
              remove_avatar: '1',
              user: {
                name: user.name
              }
            }

      aggregate_failures do
        expect(response).to redirect_to(settings_path)
        expect(user.reload.avatar).not_to be_attached
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
        expect(stream.text).to include(I18n.t('flash.settings.update_success'))
        expect(notice_surface['data-notice-surface-auto-dismiss-value']).to eq('true')
      end
    end

    it 'JSON更新成功時にlocale経由のmessageを返す' do
      patch settings_path,
            params: { user: { theme_preference: 'dark' } },
            as: :json

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.parsed_body).to include(
          'ok' => true,
          'message' => I18n.t('flash.settings.update_success')
        )
      end
    end

    it 'JSON更新失敗時にlocale経由のmessageを返す' do
      allow_any_instance_of(User).to receive(:update).and_return(false)

      patch settings_path,
            params: { user: { theme_preference: 'dark' } },
            as: :json

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to include(
          'ok' => false,
          'message' => I18n.t('flash.settings.update_failure')
        )
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
