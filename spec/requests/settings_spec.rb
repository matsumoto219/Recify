require 'rails_helper'

RSpec.describe 'Settings', type: :request do
  let(:user) { create(:user) }
  let(:avatar_path) { Rails.root.join('spec/fixtures/files/receipt_sample.jpg') }
  let(:avatar_upload) { Rack::Test::UploadedFile.new(avatar_path, 'image/jpeg') }

  before do
    ActionMailer::Base.deliveries.clear
    sign_in user
  end

  after do
    ActionMailer::Base.deliveries.clear
  end

  def confirmation_token_from(message)
    message.body.decoded.match(/confirmation_token=([^"'\s]+)/)[1]
  end

  def expect_common_mail_layout(message)
    body = message.body.decoded

    aggregate_failures do
      expect(body).to include('<!DOCTYPE html>')
      expect(body).to include(I18n.t('auth.mailer.layout.app_name'))
      expect(body).to include(I18n.t('auth.mailer.layout.tagline'))
      expect(body).to include(I18n.t('auth.mailer.layout.footer_notice').lines.first.strip)
    end
  end

  def expect_mail_cta_with_fallback(message, action_label)
    body = message.body.decoded

    aggregate_failures do
      expect_common_mail_layout(message)
      expect(body).to include(action_label)
      expect(body).to include(I18n.t('auth.mailer.common.fallback_url'))
    end
  end

  def form_for_update_context(document, update_context)
    document.css('form').find do |form|
      form.at_css("input[type=\"hidden\"][name=\"update_context\"][value=\"#{update_context}\"]")
    end
  end

  def current_password_input_for(document, update_context)
    form_for_update_context(document, update_context).at_css('input[name="user[current_password]"]')
  end

  describe 'GET /settings' do
    it 'shows delete confirmation toggle' do
      get settings_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('settings.index.usage.delete_confirmation.label'))
        expect(response.body).to include(I18n.t('settings.index.usage.delete_confirmation.description'))
        expect(document.at_css('input[name="delete_confirmation_enabled"]')).to be_present
      end
    end

    it '通知設定toggleを表示する' do
      get settings_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('settings.index.usage.push_notification.label'))
        expect(response.body).to include(I18n.t('settings.index.usage.push_notification.description'))
        expect(document.at_css('input[name="push_notification_enabled"]')).to be_present
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

    it 'guestには内部用メールアドレスを表示しない' do
      sign_out user
      guest = User.guest!
      sign_in guest

      get settings_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(guest.reload.name).to be_blank
        expect(response.body).to include(I18n.t('users.display.guest_name'))
        expect(response.body).to include(I18n.t('settings.index.user.email_unregistered'))
        expect(response.body).not_to include(guest.email)
      end
    end

    it 'guestがプロフィール編集で名前を空にしてもheader/avatarに内部メールを表示しない' do
      sign_out user
      guest = User.guest!
      fake_email = guest.email
      sign_in guest

      patch user_registration_path,
            params: {
              update_context: 'account',
              user: {
                name: ''
              }
            }

      follow_redirect!
      document = Nokogiri::HTML(response.body)
      avatar_fallbacks = document.css('[data-avatar-fallback]').map(&:text)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(guest.reload.name).to be_blank
        expect(response.body).to include(I18n.t('users.display.guest_name'))
        expect(response.body).to include(I18n.t('users.display.email_unregistered'))
        expect(response.body).not_to include(fake_email)
        expect(avatar_fallbacks).to include(I18n.t('users.display.guest_name').first)
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

    it 'account form sends account update context' do
      get settings_account_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('input[type="hidden"][name="update_context"]')['value']).to eq('account')
      end
    end
  end

  describe 'GET /settings/security' do
    it 'renders security copy through locale keys' do
      get settings_security_path

      document = Nokogiri::HTML(response.body)
      update_context_values = document.css('input[type="hidden"][name="update_context"]').map { |input| input['value'] }
      email_change_control_row = document.at_css('[data-email-change-control-row]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('settings.security.title'))
        expect(response.body).to include(I18n.t('settings.security.email.title'))
        expect(response.body).to include(I18n.t('settings.security.email.submit'))
        expect(response.body).to include(I18n.t('settings.security.password.title'))
        expect(response.body).to include(I18n.t('settings.security.auth.two_factor.title'))
        expect(response.body).to include(I18n.t('settings.security.auth.passkey.title'))
        expect(update_context_values).to include('email', 'security')
        expect(email_change_control_row['class']).to include('space-y-6')
        expect(email_change_control_row['class']).to include('md:grid')
        expect(email_change_control_row['class']).to include('md:grid-cols-2')
        expect(email_change_control_row['class']).to include('md:items-end')
      end
    end

    it 'guestには本登録カードだけを表示する' do
      sign_out user
      guest = User.guest!
      sign_in guest

      get settings_security_path

      document = Nokogiri::HTML(response.body)
      update_context_values = document.css('input[type="hidden"][name="update_context"]').map { |input| input['value'] }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('settings.security.guest_registration.title'))
        expect(response.body).to include(I18n.t('settings.security.guest_registration.description'))
        expect(response.body).not_to include(I18n.t('settings.security.email.title'))
        expect(response.body).not_to include(I18n.t('settings.security.password.title'))
        expect(response.body).not_to include(I18n.t('settings.security.auth.two_factor.title'))
        expect(response.body).not_to include(I18n.t('settings.security.auth.passkey.title'))
        expect(response.body).not_to include(guest.email)
        expect(update_context_values).to eq([ 'guest_registration' ])
      end
    end

    it '通常ユーザーのメール変更待ちを表示する' do
      user.update!(email: 'pending-normal@example.com')
      ActionMailer::Base.deliveries.clear

      get settings_security_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('settings.security.email.pending', email: 'pending-normal@example.com'))
        expect(response.body).to include(I18n.t('settings.security.email.resend_confirmation'))
        expect(document.at_css("a[href='#{new_user_confirmation_path}']")).to be_present
      end
    end

    it 'guest本登録申請中の送信先を表示する' do
      sign_out user
      guest = User.guest!
      fake_email = guest.email
      guest.start_guest_registration(
        email: 'pending-guest@example.com',
        password: 'password123',
        password_confirmation: 'password123'
      )
      ActionMailer::Base.deliveries.clear
      sign_in guest

      get settings_security_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('settings.security.guest_registration.pending.title'))
        expect(response.body).to include(I18n.t('settings.security.guest_registration.pending.sent_to', email: 'pending-guest@example.com'))
        expect(response.body).to include(I18n.t('settings.security.guest_registration.pending.resend'))
        expect(document.at_css("a[href='#{new_user_confirmation_path}']")).to be_present
        expect(response.body).not_to include(fake_email)
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

    it 'invalid account update renders account form with field errors' do
      patch user_registration_path,
            params: {
              update_context: 'account',
              user: {
                name: 'a' * 31
              }
            }

      document = Nokogiri::HTML(response.body)
      name_input = document.at_css('input[name="user[name]"]')
      invalid_user = User.new(name: 'a' * 31, email: 'name_too_long@example.com', password: 'password123')
      invalid_user.valid?
      name_error = invalid_user.errors.full_messages_for(:name).first

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('settings.account.title'))
        expect(response.body).not_to include(I18n.t('auth.registrations.edit.title'))
        expect(name_input).to be_present
        expect(name_input['class']).to include('input-field-error')
        expect(response.body).to include(name_error)
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
        expect(response.body).to include(I18n.t('settings.security.title'))
        expect(response.body).not_to include(I18n.t('auth.registrations.edit.title'))
        expect(response.body).to include(password_error)
        expect(response.body).to include(confirmation_error)
      end
    end

    it 'guest本登録申請で新メールをunconfirmed_emailに入れて確認メールだけ送る' do
      sign_out user
      guest = User.guest!
      fake_email = guest.email
      sign_in guest
      ActionMailer::Base.deliveries.clear

      patch user_registration_path,
            params: {
              update_context: 'guest_registration',
              user: {
                email: 'guest-upgrade@example.com',
                password: 'password123',
                password_confirmation: 'password123'
              }
            }

      guest.reload
      delivered_recipients = ActionMailer::Base.deliveries.flat_map(&:to)
      delivered_body = ActionMailer::Base.deliveries.last.body.decoded

      aggregate_failures do
        expect(response).to redirect_to(settings_security_path(anchor: 'guest-registration'))
        expect(flash[:notice]).to eq(I18n.t('flash.users.guest_registration.confirmation_sent'))
        expect(guest).to be_guest
        expect(guest.email).to eq(fake_email)
        expect(guest.unconfirmed_email).to eq('guest-upgrade@example.com')
        expect(guest).to be_valid_password('password123')
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(delivered_recipients).to include('guest-upgrade@example.com')
        expect(delivered_recipients).not_to include(fake_email)
        expect(delivered_body).to include('guest-upgrade@example.com')
        expect(delivered_body).not_to include(fake_email)
        expect_mail_cta_with_fallback(ActionMailer::Base.deliveries.last, I18n.t('auth.mailer.confirmation_instructions.action'))
      end
    end

    it 'guest本登録はconfirmation完了で本登録ユーザーにする' do
      sign_out user
      guest = User.guest!
      sign_in guest
      ActionMailer::Base.deliveries.clear

      patch user_registration_path,
            params: {
              update_context: 'guest_registration',
              user: {
                email: 'guest-confirmed@example.com',
                password: 'password123',
                password_confirmation: 'password123'
              }
            }

      token = confirmation_token_from(ActionMailer::Base.deliveries.last)

      get user_confirmation_path(confirmation_token: token)

      aggregate_failures do
        expect(guest.reload).not_to be_guest
        expect(guest.email).to eq('guest-confirmed@example.com')
        expect(guest.unconfirmed_email).to be_nil
      end
    end

    it '通常ユーザーのメール変更はcurrent_passwordを必須にする' do
      patch user_registration_path,
            params: {
              update_context: 'email',
              user: {
                email: 'new-address@example.com',
                current_password: ''
              }
            }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.email).not_to eq('new-address@example.com')
        expect(user.unconfirmed_email).to be_nil
      end
    end

    it 'メール変更のcurrent_passwordエラーはメール変更カードだけに表示する' do
      patch user_registration_path,
            params: {
              update_context: 'email',
              user: {
                email: 'wrong-password-email-change@example.com',
                current_password: 'wrong-password'
              }
            }

      document = Nokogiri::HTML(response.body)
      email_current_password = current_password_input_for(document, 'email')
      password_current_password = current_password_input_for(document, 'security')

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(email_current_password['class']).to include('input-field-error')
        expect(password_current_password['class']).not_to include('input-field-error')
      end
    end

    it '通常ユーザーのメール変更は確認完了まで旧メールを維持する' do
      old_email = user.email

      patch user_registration_path,
            params: {
              update_context: 'email',
              user: {
                email: 'reconfirmable-new@example.com',
                current_password: 'password'
              }
            }

      confirmation_mail = ActionMailer::Base.deliveries.find { |mail| mail.to.include?('reconfirmable-new@example.com') }
      email_changed_mail = ActionMailer::Base.deliveries.find { |mail| mail.to.include?(old_email) }
      user.reload
      delivered_recipients = ActionMailer::Base.deliveries.flat_map(&:to)

      aggregate_failures do
        expect(response).to redirect_to(settings_security_path(anchor: 'email'))
        expect(flash[:notice]).to eq(I18n.t('flash.users.email_change.confirmation_sent'))
        expect(user.email).to eq(old_email)
        expect(user.unconfirmed_email).to eq('reconfirmable-new@example.com')
        expect(delivered_recipients).to include('reconfirmable-new@example.com')
        expect(delivered_recipients).to include(old_email)
        expect(confirmation_mail.body.decoded).to include('reconfirmable-new@example.com')
        expect_mail_cta_with_fallback(confirmation_mail, I18n.t('auth.mailer.confirmation_instructions.action'))
        expect_common_mail_layout(email_changed_mail)
        expect(email_changed_mail.body.decoded).to include(I18n.t('auth.mailer.email_changed.title'))
        expect(email_changed_mail.body.decoded).not_to include(I18n.t('auth.mailer.common.fallback_url'))
      end

      token = confirmation_token_from(confirmation_mail)

      get user_confirmation_path(confirmation_token: token)

      aggregate_failures do
        expect(user.reload.email).to eq('reconfirmable-new@example.com')
        expect(user.unconfirmed_email).to be_nil
      end
    end

    it 'パスワード変更のcurrent_passwordエラーはパスワード変更カードだけに表示する' do
      patch user_registration_path,
            params: {
              update_context: 'security',
              user: {
                current_password: 'wrong-password',
                password: 'new-password123',
                password_confirmation: 'new-password123'
              }
            }

      document = Nokogiri::HTML(response.body)
      email_current_password = current_password_input_for(document, 'email')
      password_current_password = current_password_input_for(document, 'security')

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(email_current_password['class']).not_to include('input-field-error')
        expect(password_current_password['class']).to include('input-field-error')
      end
    end

    it '通常ユーザーのパスワード変更は成功する' do
      patch user_registration_path,
            params: {
              update_context: 'security',
              user: {
                current_password: 'password',
                password: 'new-password123',
                password_confirmation: 'new-password123'
              }
            }

      aggregate_failures do
        expect(response).to redirect_to(settings_security_path)
        expect(user.reload).to be_valid_password('new-password123')
      end
    end

    it '通常ユーザーがguest_registration contextを叩いても拒否する' do
      patch user_registration_path,
            params: {
              update_context: 'guest_registration',
              user: {
                email: 'not-guest@example.com',
                password: 'password123',
                password_confirmation: 'password123'
              }
            }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload).not_to be_guest
        expect(user.unconfirmed_email).to be_nil
      end
    end

    it 'guestがemail contextを叩いても通常メール変更扱いしない' do
      sign_out user
      guest = User.guest!
      fake_email = guest.email
      sign_in guest
      ActionMailer::Base.deliveries.clear

      patch user_registration_path,
            params: {
              update_context: 'email',
              user: {
                email: 'guest-email-context@example.com',
                current_password: 'password'
              }
            }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(guest.reload.email).to eq(fake_email)
        expect(guest.unconfirmed_email).to be_nil
        expect(ActionMailer::Base.deliveries).to be_empty
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

    it '通知OFFなら設定保存成功のTurbo flashを表示しない' do
      user.update!(push_notification_enabled: false)

      patch settings_path,
            params: { user: { theme_preference: 'dark' } },
            headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' }

      document = Nokogiri::HTML(response.body)
      stream = document.at_css('turbo-stream[target="flash"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.media_type).to eq('text/vnd.turbo-stream.html')
        expect(stream).to be_present
        expect(stream.at_css('[data-controller~="notice-surface"]')).to be_nil
        expect(stream.text).not_to include(I18n.t('flash.settings.update_success'))
      end
    end

    it '通知OFFでも設定保存失敗のTurbo flashは表示する（現状は200でflashだけ更新する）' do
      user.update!(push_notification_enabled: false)

      patch settings_path,
            params: { user: { theme_preference: 'neon' } },
            headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' }

      document = Nokogiri::HTML(response.body)
      stream = document.at_css('turbo-stream[target="flash"]')
      notice_surface = stream.at_css('[data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.media_type).to eq('text/vnd.turbo-stream.html')
        expect(stream).to be_present
        expect(notice_surface).to be_present
        expect(stream.text).to include(I18n.t('flash.settings.update_failure'))
      end
    end

    it 'Turbo flash replaceはappend toast containerをtargetにしない' do
      patch settings_path,
            params: { user: { theme_preference: 'dark' } },
            headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' }

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('turbo-stream[target="flash"]')).to be_present
        expect(document.at_css('turbo-stream[target="toast-stream"]')).to be_nil
      end
    end

    it '削除確認OFFへのTurbo更新で通知dropdownのconfirmを消す' do
      notification = create(:notification, user:, title: '通知1')

      patch settings_path,
            params: { user: { delete_confirmation_enabled: false } },
            headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' }

      document = Nokogiri::HTML(response.body)
      stream = document.at_css('turbo-stream[target="notifications_dropdown_content"]')
      delete_form = stream.at_css("form[action='#{notification_path(notification)}'][method='post']")
      delete_button = delete_form.at_css('button')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(user.reload.delete_confirmation_enabled).to be(false)
        expect(stream).to be_present
        expect(stream['action']).to eq('replace')
        expect(delete_button['data-turbo-confirm']).to be_nil
      end
    end

    it '削除確認ONへのTurbo更新で通知dropdownのconfirmを出す' do
      user.update!(delete_confirmation_enabled: false)
      notification = create(:notification, user:, title: '通知1')

      patch settings_path,
            params: { user: { delete_confirmation_enabled: true } },
            headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' }

      document = Nokogiri::HTML(response.body)
      stream = document.at_css('turbo-stream[target="notifications_dropdown_content"]')
      delete_form = stream.at_css("form[action='#{notification_path(notification)}'][method='post']")
      delete_button = delete_form.at_css('button')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(user.reload.delete_confirmation_enabled).to be(true)
        expect(stream).to be_present
        expect(stream['action']).to eq('replace')
        expect(delete_button['data-turbo-confirm']).to eq(I18n.t('notifications.item.delete_confirm'))
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

    it 'updates delete confirmation setting to false' do
      patch settings_path,
            params: { user: { delete_confirmation_enabled: false } },
            as: :json

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(user.reload.delete_confirmation_enabled).to be(false)
        expect(response.parsed_body).to include(
          'ok' => true,
          'delete_confirmation_enabled' => false
        )
      end
    end

    it 'updates push notification setting to false' do
      patch settings_path,
            params: { user: { push_notification_enabled: false } },
            as: :json

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(user.reload.push_notification_enabled).to be(false)
        expect(response.parsed_body).to include(
          'ok' => true,
          'push_notification_enabled' => false
        )
      end
    end

    it 'updates push notification setting to true' do
      user.update!(push_notification_enabled: false)

      patch settings_path,
            params: { user: { push_notification_enabled: true } },
            as: :json

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(user.reload.push_notification_enabled).to be(true)
        expect(response.parsed_body).to include(
          'ok' => true,
          'push_notification_enabled' => true
        )
      end
    end

    it 'updates delete confirmation setting to true' do
      user.update!(delete_confirmation_enabled: false)

      patch settings_path,
            params: { user: { delete_confirmation_enabled: true } },
            as: :json

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(user.reload.delete_confirmation_enabled).to be(true)
        expect(response.parsed_body).to include(
          'ok' => true,
          'delete_confirmation_enabled' => true
        )
      end
    end
  end
end
