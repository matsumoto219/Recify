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
        expect(response.body).to include(I18n.t('settings.index.usage.receipt_item_delete_confirmation.label'))
        expect(response.body).to include(I18n.t('settings.index.usage.receipt_item_delete_confirmation.description'))
        expect(document.at_css('input[name="receipt_item_delete_confirmation_enabled"]')).to be_present
      end
    end

    it 'renders settings index copy through locale keys' do
      get settings_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('settings.index.title'))
        expect(response.body).to include(I18n.t('settings.index.sections.system_status'))
        expect(response.body).to include(I18n.t('settings.index.sections.security'))
        expect(response.body).to include(I18n.t('settings.index.sections.appearance'))
        expect(response.body).to include(I18n.t('settings.index.sections.usage'))
        expect(response.body).to include(I18n.t('settings.index.danger.delete_account'))
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
      avatar_images = document.css('[data-avatar-image]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(avatar_images).to be_present
        expect(avatar_images.map { |image| image['alt'] }).to all(eq(I18n.t('shared.avatar.default_alt')))
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

    it 'settingsに実ストレージ使用量を表示する' do
      user.update!(storage_limit_bytes: 10.megabytes)
      user.avatar.attach(
        io: StringIO.new('a' * 1.megabyte),
        filename: 'avatar-storage.jpg',
        content_type: 'image/jpeg'
      )

      get settings_path

      document = Nokogiri::HTML(response.body)
      meter = document.at_css('[data-storage-usage-meter][data-storage-usage-context="settings"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(meter).to be_present
        expect(meter.text.squish).to include('1MB / 10MB')
        expect(meter.at_css('[data-storage-usage-used]').text).to eq('1MB')
        expect(meter.at_css('[data-storage-usage-used]')['class']).to include('text-2xl')
        expect(meter.at_css('[data-storage-usage-used]')['class']).to include('font-bold')
        expect(meter.at_css('[data-storage-usage-limit]').text.squish).to eq('/ 10MB')
        expect(meter.at_css('[data-storage-usage-limit]')['class']).to include('text-sm')
        expect(meter.at_css('[data-storage-usage-limit]')['class']).to include('token-text-muted')
        expect(meter.text).to include(I18n.t('shared.storage_usage.remaining', size: '9MB'))
      end
    end

    it 'settingsのカード順を維持する' do
      get settings_path
      document = Nokogiri::HTML(response.body)
      cards = document.css('section[data-controller~="settings"] > div.space-y-6 > section')

      ordered_labels = [
        I18n.t('settings.index.user.edit_profile'),
        I18n.t('settings.index.sections.security'),
        I18n.t('settings.index.sections.system_status'),
        I18n.t('settings.index.sections.storage'),
        I18n.t('settings.index.sections.appearance'),
        I18n.t('settings.index.sections.usage'),
        I18n.t('settings.index.sections.account_actions')
      ]

      aggregate_failures do
        expect(cards.size).to be >= ordered_labels.size
        ordered_labels.each_with_index do |label, index|
          expect(cards[index].text).to include(label)
        end
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

    it 'renders account copy through locale keys' do
      get settings_account_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('settings.account.title'))
        expect(response.body).to include(I18n.t('settings.account.avatar.title'))
        expect(response.body).to include(I18n.t('settings.account.fields.name'))
        expect(response.body).to include(I18n.t('settings.account.buttons.save'))
      end
    end
  end

  describe 'GET /settings/security' do
    it 'renders security copy through locale keys' do
      get settings_security_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('settings.security.title'))
        expect(response.body).to include(I18n.t('settings.security.email.title'))
        expect(response.body).to include(I18n.t('settings.security.password.title'))
        expect(response.body).to include(I18n.t('settings.security.auth.two_factor.title'))
        expect(response.body).to include(I18n.t('settings.security.auth.passkey.title'))
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
        expect(response.body).to include(I18n.t('activerecord.errors.models.user.attributes.avatar.invalid_content_type'))
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
        expect(response.body).to include(I18n.t('activerecord.errors.models.user.attributes.avatar.file_too_large'))
      end
    ensure
      large_file&.close
      large_file&.unlink
    end

    it 'ストレージ上限超過時はavatarを保存しない' do
      user.update!(storage_limit_bytes: 1)

      patch user_registration_path,
            params: {
              update_context: 'account',
              user: {
                name: user.name,
                avatar: avatar_upload
              }
            }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.avatar).not_to be_attached
        expect(response.body).to include(I18n.t('flash.storage.quota_exceeded'))
      end
    end

    it 'avatar差し替え時は既存blob分を差し引いて容量判定する' do
      user.avatar.attach(avatar_upload)
      user.update!(storage_limit_bytes: user.avatar.blob.byte_size)

      patch user_registration_path,
            params: {
              update_context: 'account',
              user: {
                name: user.name,
                avatar: Rack::Test::UploadedFile.new(avatar_path, 'image/jpeg')
              }
            }

      aggregate_failures do
        expect(response).to redirect_to(settings_path)
        expect(user.reload.avatar).to be_attached
      end
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

  describe 'PATCH /users security' do
    it 'blank password update shows locale-backed field errors' do
      patch user_registration_path,
            params: {
              update_context: 'security',
              user: {
                current_password: 'password',
                password: '',
                password_confirmation: ''
              }
            }

      password_error = "#{I18n.t('activerecord.attributes.user.password')}#{I18n.t('activerecord.errors.models.user.attributes.password.blank')}"
      confirmation_error = "#{I18n.t('activerecord.attributes.user.password_confirmation')}#{I18n.t('activerecord.errors.models.user.attributes.password_confirmation.blank')}"

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(password_error)
        expect(response.body).to include(confirmation_error)
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
