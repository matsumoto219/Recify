require 'rails_helper'

RSpec.describe 'Settings', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:avatar_path) { Rails.root.join('spec/fixtures/files/receipt_sample.jpg') }
  let(:avatar_upload) { Rack::Test::UploadedFile.new(avatar_path, 'image/jpeg') }

  before do
    ActionMailer::Base.deliveries.clear
    LegalDocuments::Sync.call
    sign_in user
  end

  after do
    ActionMailer::Base.deliveries.clear
  end

  def confirmation_token_from(message)
    mail_html_body(message).match(/confirmation_token=([^"'\s]+)/)[1]
  end

  def mail_html_body(message)
    message.html_part&.body&.decoded || message.body.decoded
  end

  def flash_message(type)
    value = flash[type]
    return value unless value.is_a?(Hash)

    value["message"] || value[:message]
  end

  def expect_common_mail_layout(message)
    body = mail_html_body(message)

    aggregate_failures do
      expect(body).to include('<!DOCTYPE html>')
      expect(body).to include(I18n.t('auth.mailer.layout.app_name'))
      expect(body).to include(I18n.t('auth.mailer.layout.tagline'))
      expect(body).to include(I18n.t('auth.mailer.layout.footer_notice').lines.first.strip)
    end
  end

  def expect_mail_cta_with_fallback(message, action_label)
    body = mail_html_body(message)

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

  def password_reveal_wrapper_for(input)
    input&.ancestors&.find do |node|
      node['data-controller'].to_s.split.include?('password-reveal')
    end
  end

  def expect_password_reveal_for(input)
    wrapper = password_reveal_wrapper_for(input)
    button = wrapper&.at_css('button[data-action="password-reveal#toggle"]')

    aggregate_failures do
      expect(wrapper).to be_present
      expect(input['data-password-reveal-target']).to eq('input')
      expect(button).to be_present
      expect(button['aria-label']).to eq(I18n.t('shared.password_reveal.show'))
      expect(button['aria-pressed']).to eq('false')
    end
  end

  def expect_no_password_reveal_for(input)
    expect(password_reveal_wrapper_for(input)).to be_nil
  end

  def current_legal_document(document_type)
    LegalDocument.current!(document_type, locale: :ja)
  end

  def legal_acceptances_by_type(user)
    user.legal_acceptances.index_by(&:document_type)
  end

  def expect_current_legal_acceptances(user, context:, accepted_at: nil)
    acceptances = legal_acceptances_by_type(user.reload)
    terms_document = current_legal_document(:terms)
    privacy_document = current_legal_document(:privacy)

    aggregate_failures do
      expect(acceptances.keys).to contain_exactly("terms", "privacy")
      expect(acceptances.fetch("terms")).to have_attributes(
        legal_document: terms_document,
        version: terms_document.version,
        locale: terms_document.locale,
        acceptance_context: context
      )
      expect(acceptances.fetch("privacy")).to have_attributes(
        legal_document: privacy_document,
        version: privacy_document.version,
        locale: privacy_document.locale,
        acceptance_context: context
      )
      expect(acceptances.values).to all(have_attributes(accepted_at: accepted_at || be_present))
    end
  end

  describe 'GET /settings' do
    it 'サポートと法務導線を分けて表示する' do
      get settings_path

      document = Nokogiri::HTML(response.body)
      support_heading = document.xpath("//h2[normalize-space()='#{I18n.t('settings.index.sections.support')}']").first
      support_icon = support_heading&.parent&.at_css('.material-symbols-outlined')&.text&.strip
      legal_heading = document.xpath("//h2[normalize-space()='#{I18n.t('settings.index.sections.legal')}']").first
      legal_icon = legal_heading&.parent&.at_css('.material-symbols-outlined')&.text&.strip
      contact_link = document.at_css("a[href='#{contact_path}']")
      announcements_link = document.at_css("a[href='#{announcements_path}']")
      terms_link = document.at_css("a[href='#{terms_path}']")
      privacy_link = document.at_css("a[href='#{privacy_path}']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to include('href="#"')
        expect(response.body).not_to match(/translation missing/i)
        expect(document.at_css('[data-controller~="legal-dialog"]')).to be_nil
        expect(response.body).to include(I18n.t('settings.index.sections.support'))
        expect(response.body).to include(I18n.t('settings.index.sections.legal'))
        expect(contact_link&.text&.squish).to include(I18n.t('settings.index.support.contact'))
        expect(announcements_link&.text&.squish).to include(I18n.t('settings.index.support.announcements'))
        expect(terms_link&.text&.squish).to include(I18n.t('settings.index.legal.terms'))
        expect(privacy_link&.text&.squish).to include(I18n.t('settings.index.legal.privacy'))
        expect(support_icon).to eq('contact_support')
        expect(legal_icon).to eq('policy')
      end
    end

    it 'sidebarは問い合わせの下に設定を表示する' do
      get settings_path

      document = Nokogiri::HTML(response.body)
      sidebar_hrefs = document.css('#desktop-sidebar a').map { |link| link['href'] }

      aggregate_failures do
        expect(sidebar_hrefs).to include(contact_path, settings_path)
        expect(sidebar_hrefs.index(contact_path)).to be < sidebar_hrefs.index(settings_path)
      end
    end

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

    it 'アカウント操作section headerに退会系アイコンを表示する' do
      get settings_path

      document = Nokogiri::HTML(response.body)
      account_actions_heading = document.xpath("//h2[normalize-space()='#{I18n.t('settings.index.sections.account_actions')}']").first
      account_actions_icon = account_actions_heading&.parent&.at_css('.material-symbols-outlined')&.text&.strip

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(account_actions_icon).to eq('person_off')
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

    it 'レシート画像保存toggleを表示する' do
      get settings_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('settings.index.usage.keep_receipt_images.label'))
        expect(response.body).to include('レシートを登録する際、画像を保存します')
        expect(document.at_css('input[name="keep_receipt_images"]')).to be_present
      end
    end

    it '計算設定を表示する' do
      get settings_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('settings.index.sections.calculation'))
        expect(response.body).to include(I18n.t('settings.index.calculation.description'))
        expect(response.body).to include(I18n.t('settings.index.calculation.hint'))
        expect(document.at_css('input[name="tax_rounding_mode"][value="floor"]')).to be_present
        expect(document.at_css('input[name="discount_rounding_mode"][value="round"]')).to be_present
      end
    end

    it 'renders settings index copy through locale keys' do
      get settings_path

      document = Nokogiri::HTML(response.body)
      delete_form = document.at_css("form[action='#{user_registration_path}'][method='post']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('settings.index.title'))
        expect(response.body).to include(I18n.t('settings.index.sections.system_status'))
        expect(response.body).to include(I18n.t('settings.index.sections.security'))
        expect(response.body).to include(I18n.t('settings.index.sections.appearance'))
        expect(response.body).to include(I18n.t('settings.index.sections.calculation'))
        expect(response.body).to include(I18n.t('settings.index.sections.usage'))
        expect(response.body).to include(I18n.t('settings.index.danger.delete_account'))
        expect(delete_form['data-confirm-variant']).to eq('danger')
        expect(delete_form['data-confirm-icon']).to eq('delete')
        expect(delete_form['data-confirm-confirm-label']).to eq(I18n.t('settings.index.danger.delete_account'))
      end
    end

    it 'maintenance notice is hidden by default' do
      get settings_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to include(I18n.t('shared.maintenance_notice.body'))
      end
    end

    it 'maintenance notice is shown when the system setting is enabled' do
      create(:system_setting, key: 'ui.maintenance_notice_enabled', value: SystemSettings.stored_value(true))

      get settings_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('shared.maintenance_notice.title'))
        expect(response.body).to include(I18n.t('shared.maintenance_notice.body'))
      end
    end

    it 'maintenance notice uses configured title and body when present' do
      create(:system_setting, key: 'ui.maintenance_notice_enabled', value: SystemSettings.stored_value(true))
      create(:system_setting, key: 'ui.maintenance_notice_title', value: SystemSettings.stored_value('重要なお知らせ'))
      create(:system_setting, key: 'ui.maintenance_notice_body', value: SystemSettings.stored_value("1行目\n2行目"))

      get settings_path

      document = Nokogiri::HTML(response.body)
      notice = document.at_css('[data-controller~="notice-surface"]')
      body_node = notice.css('p').find { |node| node.text.include?('1行目') && node.text.include?('2行目') }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(notice.text).to include('重要なお知らせ')
        expect(notice.text).to include('1行目')
        expect(notice.text).to include('2行目')
        expect(body_node).to be_present
        expect(body_node['class']).to include('whitespace-pre-wrap')
      end
    end

    it 'maintenance notice falls back to locale when configured text is blank' do
      create(:system_setting, key: 'ui.maintenance_notice_enabled', value: SystemSettings.stored_value(true))
      create(:system_setting, key: 'ui.maintenance_notice_title', value: SystemSettings.stored_value(''))
      create(:system_setting, key: 'ui.maintenance_notice_body', value: SystemSettings.stored_value(''))

      get settings_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('shared.maintenance_notice.title'))
        expect(response.body).to include(I18n.t('shared.maintenance_notice.body'))
      end
    end

    it 'maintenance notice escapes configured HTML text' do
      create(:system_setting, key: 'ui.maintenance_notice_enabled', value: SystemSettings.stored_value(true))
      create(:system_setting, key: 'ui.maintenance_notice_title', value: SystemSettings.stored_value('<strong>重要</strong>'))
      create(:system_setting, key: 'ui.maintenance_notice_body', value: SystemSettings.stored_value("<script>alert('x')</script>"))

      get settings_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('&lt;strong&gt;重要&lt;/strong&gt;')
        expect(response.body).to include('&lt;script&gt;alert')
        expect(response.body).not_to include('<strong>重要</strong>')
        expect(response.body).not_to include("<script>alert('x')</script>")
      end
    end

    it 'maintenance notice is hidden when the system setting is disabled' do
      create(:system_setting, key: 'ui.maintenance_notice_enabled', value: SystemSettings.stored_value(false))

      get settings_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to include(I18n.t('shared.maintenance_notice.body'))
      end
    end

    it 'evaluates maintenance notice through the SystemSettings facade' do
      allow(SystemSettings).to receive(:enabled?).and_call_original

      get settings_path

      expect(SystemSettings).to have_received(:enabled?).with('ui.maintenance_notice_enabled', user: user)
    end

    it 'login_restricted中の既存一般ユーザーsessionはsign outしてログイン画面へ戻す' do
      create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))

      get settings_path

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(response).to have_http_status(:see_other)
        expect(flash[:alert]).to eq(I18n.t('shared.maintenance_mode.body'))
      end

      get settings_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it 'login_restricted中の既存guest sessionはsign outしてログイン画面へ戻す' do
      sign_out user
      guest = create(:user, guest: true)
      sign_in guest
      create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))

      get settings_path

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(response).to have_http_status(:see_other)
        expect(flash[:alert]).to eq(I18n.t('shared.maintenance_mode.body'))
      end

      get settings_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it 'login_restricted中でもadmin sessionは維持する' do
      sign_out user
      admin = create(:user, :admin)
      sign_in admin
      create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))

      get settings_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('settings.index.title'))
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
        expect(avatar_images.map { |image| image['src'] }).to all(include('/rails/active_storage/blobs/'))
        expect(avatar_images.map { |image| image['src'] }.join("\n")).not_to include('/rails/active_storage/representations/')
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
        I18n.t('settings.index.sections.calculation'),
        I18n.t('settings.index.sections.usage'),
        I18n.t('settings.index.sections.support'),
        I18n.t('settings.index.sections.legal'),
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
      create(:system_setting, key: 'limits.avatar_image_max_file_size_bytes', value: SystemSettings.stored_value(6.megabytes))

      get settings_account_path

      document = Nokogiri::HTML(response.body)
      avatar_max_size = ActiveSupport::NumberHelper.number_to_human_size(User.avatar_max_file_size)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('[data-controller~="avatar-preview"]')).to be_present
        expect(document.at_css('[data-controller~="avatar-preview"]')['data-avatar-preview-invalid-type-message-value']).to eq(I18n.t('settings.account.avatar.validation.invalid_type'))
        expect(document.at_css('[data-controller~="avatar-preview"]')['data-avatar-preview-file-too-large-message-value']).to eq(I18n.t('settings.account.avatar.validation.file_too_large', max_size: avatar_max_size))
        expect(document.at_css('[data-controller~="avatar-preview"]')['data-avatar-preview-max-file-size-bytes-value']).to eq(User.avatar_max_file_size.to_s)
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
      password_form = form_for_update_context(document, 'security')
      current_password_input = password_form.at_css('input[name="user[current_password]"]')
      password_input = password_form.at_css('input[name="user[password]"]')
      password_confirmation_input = password_form.at_css('input[name="user[password_confirmation]"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('settings.security.title'))
        expect(response.body).to include(I18n.t('settings.security.email.title'))
        expect(response.body).to include(I18n.t('settings.security.email.submit'))
        expect(response.body).to include(I18n.t('settings.security.password.title'))
        expect(response.body).to include(I18n.t('settings.security.auth.two_factor.title'))
        expect(response.body).to include('認証アプリ (TOTP)')
        expect(response.body).not_to include('2要素認証 (2FA)')
        expect(response.body).to include(I18n.t('settings.security.auth.passkey.title'))
        expect(update_context_values).to include('email', 'security')
        expect(email_change_control_row['class']).to include('space-y-6')
        expect(email_change_control_row['class']).to include('md:grid')
        expect(email_change_control_row['class']).to include('md:grid-cols-2')
        expect(email_change_control_row['class']).to include('md:items-end')
        expect(current_password_input.attribute('required')).to be_present
        expect(password_input.attribute('required')).to be_present
        expect(password_confirmation_input.attribute('required')).to be_present
        expect_no_password_reveal_for(current_password_input)
        expect_password_reveal_for(password_input)
        expect_password_reveal_for(password_confirmation_input)
      end
    end

    it 'guestには本登録カードだけを表示する' do
      sign_out user
      guest = User.guest!
      sign_in guest

      get settings_security_path

      document = Nokogiri::HTML(response.body)
      update_context_values = document.css('input[type="hidden"][name="update_context"]').map { |input| input['value'] }
      guest_registration_card = document.at_css('#guest-registration')
      terms_link = guest_registration_card.at_css("a[href='#{terms_path}']")
      privacy_link = guest_registration_card.at_css("a[href='#{privacy_path}']")
      terms_dialog = guest_registration_card.at_css('dialog#guest-registration-terms-dialog')
      privacy_dialog = guest_registration_card.at_css('dialog#guest-registration-privacy-dialog')
      terms_full_link = terms_dialog.at_css("a[href='#{terms_path}']")
      privacy_full_link = privacy_dialog.at_css("a[href='#{privacy_path}']")
      terms_close_button = terms_dialog.at_css("button[data-action='legal-dialog#close']")
      privacy_close_button = privacy_dialog.at_css("button[data-action='legal-dialog#close']")
      password_input = guest_registration_card.at_css('input[name="user[password]"]')
      password_confirmation_input = guest_registration_card.at_css('input[name="user[password_confirmation]"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('settings.security.guest_registration.title'))
        expect(response.body).to include(I18n.t('settings.security.guest_registration.description'))
        expect(response.body).to include(I18n.t('settings.security.guest_registration.legal_agreement.terms'))
        expect(terms_link&.text&.strip).to eq(I18n.t('settings.security.guest_registration.legal_agreement.terms'))
        expect(privacy_link&.text&.strip).to eq(I18n.t('settings.security.guest_registration.legal_agreement.privacy'))
        expect(terms_link['data-action']).to include('legal-dialog#open')
        expect(terms_link['data-legal-dialog-dialog-param']).to eq('terms')
        expect(privacy_link['data-action']).to include('legal-dialog#open')
        expect(privacy_link['data-legal-dialog-dialog-param']).to eq('privacy')
        expect(terms_dialog['data-legal-dialog-target']).to eq('dialog')
        expect(terms_dialog['aria-modal']).to eq('true')
        expect(terms_dialog['aria-labelledby']).to eq('guest-registration-terms-dialog-title')
        expect(terms_dialog.at_css('#guest-registration-terms-dialog-title')).to be_present
        expect(terms_close_button['aria-label']).to eq(I18n.t('legal.dialog.close'))
        expect(terms_dialog.text).to include(I18n.t('legal.dialog.summary_label'))
        expect(terms_dialog.text).to include(I18n.t('legal.dialog.terms.summary_notice'))
        expect(terms_dialog.text).to include(I18n.t('legal.dialog.terms.items').first)
        expect(terms_dialog.text).not_to include(I18n.t('legal.dialog.summary_notice'))
        expect(terms_full_link.text).to include(I18n.t('legal.dialog.open_full_terms'))
        expect(privacy_dialog['data-legal-dialog-target']).to eq('dialog')
        expect(privacy_dialog['aria-modal']).to eq('true')
        expect(privacy_dialog['aria-labelledby']).to eq('guest-registration-privacy-dialog-title')
        expect(privacy_dialog.at_css('#guest-registration-privacy-dialog-title')).to be_present
        expect(privacy_close_button['aria-label']).to eq(I18n.t('legal.dialog.close'))
        expect(privacy_dialog.text).to include(I18n.t('legal.dialog.summary_label'))
        expect(privacy_dialog.text).not_to include('正式本文')
        expect(privacy_dialog.text).not_to include('正式な本文は公開前')
        expect(privacy_full_link.text).to include(I18n.t('legal.dialog.open_full_privacy'))
        expect(guest_registration_card.at_css("a[href='#']")).to be_nil
        expect(document.at_css("input[type='checkbox'][name='user[legal_agreement]']")).to be_present
        expect(response.body).not_to include(I18n.t('settings.security.email.title'))
        expect(response.body).not_to include(I18n.t('settings.security.password.title'))
        expect(response.body).not_to include(I18n.t('settings.security.auth.two_factor.title'))
        expect(response.body).not_to include(I18n.t('settings.security.auth.passkey.title'))
        expect(response.body).not_to include(guest.email)
        expect(update_context_values).to eq([ 'guest_registration' ])
        expect_password_reveal_for(password_input)
        expect_password_reveal_for(password_confirmation_input)
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

    it 'TOTP未設定ならrecovery code残数通知を表示しない' do
      get settings_security_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to include(I18n.t('settings.security.auth.recovery_codes.status.ok.title'))
        expect(response.body).not_to include(I18n.t('settings.security.auth.recovery_codes.status.low.title'))
        expect(response.body).not_to include(I18n.t('settings.security.auth.recovery_codes.status.empty.title'))
        expect(response.body).not_to include(I18n.t('settings.security.auth.recovery_codes.status.missing.title'))
      end
    end

    it 'recovery codeが3件以上なら通常表示にする' do
      create(:totp_credential, user: user, confirmed_at: Time.current)
      codes = TwoFactor.generate_recovery_codes_for(user: user)

      get settings_security_path

      document = Nokogiri::HTML(response.body)
      recovery_codes_form = document.at_css("form[action='#{settings_security_recovery_codes_regenerate_path}']")
      totp_disable_form = document.at_css("form[action='#{settings_security_totp_path}']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('settings.security.auth.recovery_codes.status.ok.title'))
        expect(response.body).to include(I18n.t('settings.security.auth.recovery_codes.status.ok.body', count: 10))
        expect(response.body).to include('リカバリーコード')
        expect(response.body).not_to include('回復コード')
        expect(response.body).to include(settings_security_recovery_codes_regenerate_path)
        expect(recovery_codes_form['data-confirm-variant']).to eq('danger')
        expect(recovery_codes_form['data-confirm-icon']).to eq('key')
        expect(recovery_codes_form['data-confirm-confirm-label']).to eq(I18n.t('settings.security.auth.two_factor.regenerate_recovery_codes'))
        expect(recovery_codes_form['data-confirm-title']).to eq(I18n.t('settings.security.auth.recovery_codes.regenerate_confirm_title'))
        expect(totp_disable_form['data-confirm-variant']).to eq('danger')
        expect(totp_disable_form['data-confirm-icon']).to eq('security')
        expect(totp_disable_form['data-confirm-confirm-label']).to eq(I18n.t('settings.security.auth.two_factor.disable'))
        expect(totp_disable_form['data-confirm-title']).to eq(I18n.t('settings.security.auth.two_factor.disable_confirm_title'))
        codes.each { |code| expect(response.body).not_to include(code) }
        expect(response.body).not_to include(user.recovery_codes.first.code_digest)
      end
    end

    it 'PC表示で認証アプリカードとパスキーカードの高さを揃えるclassを持つ' do
      create(:totp_credential, user: user, confirmed_at: Time.current)
      create(:passkey, user: user)
      TwoFactor.generate_recovery_codes_for(user: user)

      get settings_security_path

      document = Nokogiri::HTML(response.body)
      auth_cards = document.css('#two-factor > section')
      passkey_card = document.at_css('#passkeys')
      totp_card = auth_cards.find { |card| card['id'] != 'passkeys' }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(auth_cards.size).to eq(2)
        expect(totp_card['class']).to include('h-full')
        expect(passkey_card['class']).to include('h-full')
        expect(document.at_css('#two-factor > #passkeys')).to be_present
      end
    end

    it 'passkey登録数が0個の場合は0/10を表示し、登録ボタンを有効にする' do
      get settings_security_path

      document = Nokogiri::HTML(response.body)
      passkey_list = document.at_css('[data-passkey-list]')
      passkey_button = document.at_css('[data-passkey-target="button"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(passkey_list['class']).to include('md:max-h-[16rem]')
        expect(passkey_list['class']).to include('md:overflow-y-auto')
        expect(passkey_list['class']).to include('md:pr-1')
        expect(document.at_css('[data-passkey-registration-count]').text.squish).to include(
          I18n.t('settings.security.auth.passkey.registered_count', count: 0, limit: Passkey::MAX_PER_USER)
        )
        expect(document.at_css('[data-passkey-limit-message]')).to be_nil
        expect(passkey_button['disabled']).to be_nil
        expect(passkey_button['data-action']).to eq('click->passkey#register')
      end
    end

    it 'passkey登録数が3個の場合は3/10を表示し、登録ボタンを有効にする' do
      create_list(:passkey, 3, user: user)

      get settings_security_path

      document = Nokogiri::HTML(response.body)
      passkey_button = document.at_css('[data-passkey-target="button"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('[data-passkey-registration-count]').text.squish).to include(
          I18n.t('settings.security.auth.passkey.registered_count', count: 3, limit: Passkey::MAX_PER_USER)
        )
        expect(document.at_css('[data-passkey-limit-message]')).to be_nil
        expect(passkey_button['disabled']).to be_nil
        expect(passkey_button['data-action']).to eq('click->passkey#register')
      end
    end

    it 'passkey登録数が10個の場合は上限表示を出し、登録ボタンをdisabledにし、削除ボタンは残す' do
      passkeys = create_list(:passkey, Passkey::MAX_PER_USER, user: user)

      get settings_security_path

      document = Nokogiri::HTML(response.body)
      passkey_button = document.at_css('[data-passkey-target="button"]')
      label_input = document.at_css('#passkey-label-input')
      delete_forms = passkeys.map { |passkey| document.at_css("form[action='#{settings_passkey_path(passkey)}']") }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('[data-passkey-registration-count]').text.squish).to include(
          I18n.t('settings.security.auth.passkey.registered_count', count: Passkey::MAX_PER_USER, limit: Passkey::MAX_PER_USER)
        )
        expect(document.at_css('[data-passkey-limit-message]').text.squish).to include(I18n.t('settings.security.auth.passkey.limit_reached_notice'))
        expect(passkey_button['disabled']).to eq('disabled')
        expect(passkey_button['data-action']).to be_nil
        expect(label_input['disabled']).to eq('disabled')
        expect(delete_forms).to all(be_present)
        expect(delete_forms.first['data-confirm-variant']).to eq('danger')
        expect(delete_forms.first['data-confirm-icon']).to eq('passkey')
        expect(delete_forms.first['data-confirm-confirm-label']).to eq(I18n.t('settings.security.auth.passkey.delete'))
        expect(delete_forms.first['data-confirm-title']).to eq(I18n.t('settings.security.auth.passkey.delete_confirm_title'))
      end
    end

    it 'recovery codeが1〜2件なら注意表示にする' do
      create(:totp_credential, user: user, confirmed_at: Time.current)
      codes = TwoFactor.generate_recovery_codes_for(user: user)
      codes.first(8).each { |code| TwoFactor.verify_recovery_code(user: user, code: code) }

      get settings_security_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('settings.security.auth.recovery_codes.status.low.title'))
        expect(response.body).to include(I18n.t('settings.security.auth.recovery_codes.status.low.body', count: 2))
      end
    end

    it 'recovery codeを全て使用済みなら警告表示にする' do
      create(:totp_credential, user: user, confirmed_at: Time.current)
      codes = TwoFactor.generate_recovery_codes_for(user: user)
      codes.each { |code| TwoFactor.verify_recovery_code(user: user, code: code) }

      get settings_security_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('settings.security.auth.recovery_codes.status.empty.title'))
        expect(response.body).to include(I18n.t('settings.security.auth.recovery_codes.status.empty.body'))
        expect(response.body).to include(settings_security_recovery_codes_regenerate_path)
      end
    end

    it 'TOTP有効でrecovery code未発行なら発行導線を表示する' do
      create(:totp_credential, user: user, confirmed_at: Time.current)

      get settings_security_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('settings.security.auth.recovery_codes.status.missing.title'))
        expect(response.body).to include(I18n.t('settings.security.auth.recovery_codes.status.missing.body'))
        expect(response.body).to include(settings_security_recovery_codes_regenerate_path)
      end
    end

    it 'guest本登録申請中の送信先を表示する' do
      sign_out user
      guest = User.guest!
      fake_email = guest.email
      guest.start_guest_registration(
        email: 'pending-guest@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        legal_agreement: '1'
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

    it 'account update ignores spoofed admin param' do
      patch user_registration_path,
            params: {
              update_context: 'account',
              user: {
                name: 'Updated Safe Name',
                admin: true
              }
            }

      aggregate_failures do
        expect(response).to redirect_to(settings_path)
        expect(user.reload.name).to eq('Updated Safe Name')
        expect(user).not_to be_admin
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

    it 'image content type with non-image body is rejected and not attached' do
      invalid_file = Tempfile.new([ 'fake-avatar', '.jpg' ])
      invalid_file.write('not an image')
      invalid_file.rewind

      patch user_registration_path,
            params: {
              update_context: 'account',
              user: {
                name: user.name,
                avatar: Rack::Test::UploadedFile.new(invalid_file.path, 'image/jpeg')
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

    it 'avatar上限を超える画像は拒否し添付しない' do
      large_file = Tempfile.new([ 'large-avatar', '.jpg' ])
      large_file.binmode
      large_file.write('0' * (User.avatar_max_file_size + 1))
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
        expect(response.body).to include(
          I18n.t(
            'activerecord.errors.models.user.attributes.avatar.file_too_large',
            max_size: ActiveSupport::NumberHelper.number_to_human_size(User.avatar_max_file_size)
          )
        )
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

    it '全体storage hard stop超過時はavatarを保存しない' do
      allow(Storage).to receive(:global_quota_can_add?).and_return(false)

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
        expect(response.body).to include(I18n.t('flash.storage.global_hard_stop'))
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
      accepted_at = Time.zone.parse('2026-05-23 12:00:00')

      travel_to(accepted_at) do
        patch user_registration_path,
              params: {
                update_context: 'guest_registration',
                user: {
                  email: 'guest-upgrade@example.com',
                  password: 'password123',
                  password_confirmation: 'password123',
                  legal_agreement: '1'
                }
              }
      end

      guest.reload
      delivered_recipients = ActionMailer::Base.deliveries.flat_map(&:to)
      delivered_body = mail_html_body(ActionMailer::Base.deliveries.last)

      aggregate_failures do
        expect(response).to redirect_to(settings_security_path(anchor: 'guest-registration'))
        expect(flash_message(:notice)).to eq(I18n.t('flash.users.guest_registration.confirmation_sent'))
        expect(guest).to be_guest
        expect(guest.email).to eq(fake_email)
        expect(guest.unconfirmed_email).to eq('guest-upgrade@example.com')
        expect(guest).to be_valid_password('password123')
        expect_current_legal_acceptances(guest, context: "guest_conversion", accepted_at: accepted_at)
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(delivered_recipients).to include('guest-upgrade@example.com')
        expect(delivered_recipients).not_to include(fake_email)
        expect(delivered_body).to include('guest-upgrade@example.com')
        expect(delivered_body).not_to include(fake_email)
        expect_mail_cta_with_fallback(ActionMailer::Base.deliveries.last, I18n.t('auth.mailer.confirmation_instructions.action'))
      end

      follow_redirect!

      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(notice_surface).to be_present
        expect(notice_surface.text).to include(I18n.t('flash.users.guest_registration.confirmation_sent'))
        expect(notice_surface['data-notice-surface-auto-dismiss-value']).to eq('false')
      end
    end

    it 'current法務文書が未同期の場合はguest本登録申請を開始せず案内を表示する' do
      sign_out user
      guest = User.guest!
      fake_email = guest.email
      sign_in guest
      LegalAcceptance.delete_all
      LegalDocument.delete_all
      ActionMailer::Base.deliveries.clear

      expect do
        patch user_registration_path,
              params: {
                update_context: 'guest_registration',
                user: {
                  email: 'guest-legal-documents-missing@example.com',
                  password: 'password123',
                  password_confirmation: 'password123',
                  legal_agreement: '1'
                }
              }
      end.not_to change(LegalAcceptance, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.legal_documents.unavailable'))
        expect(guest.reload.email).to eq(fake_email)
        expect(guest.unconfirmed_email).to be_nil
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'guest本登録申請はspoofed admin paramを無視する' do
      sign_out user
      guest = User.guest!
      sign_in guest

      patch user_registration_path,
            params: {
              update_context: 'guest_registration',
              user: {
                email: 'guest-spoofed-admin@example.com',
                password: 'password123',
                password_confirmation: 'password123',
                legal_agreement: '1',
                admin: true
              }
            }

      aggregate_failures do
        expect(response).to redirect_to(settings_security_path(anchor: 'guest-registration'))
        expect(guest.reload).not_to be_admin
        expect(guest.unconfirmed_email).to eq('guest-spoofed-admin@example.com')
      end
    end

    it 'guest本登録申請で同じ確認待ちメールアドレスを重複登録できない' do
      sign_out user
      first_guest = User.guest!
      second_guest = User.guest!
      first_guest.start_guest_registration(
        email: 'duplicate-guest-pending@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        legal_agreement: '1'
      )
      ActionMailer::Base.deliveries.clear
      sign_in second_guest

      patch user_registration_path,
            params: {
              update_context: 'guest_registration',
              user: {
                email: 'duplicate-guest-pending@example.com',
                password: 'password123',
                password_confirmation: 'password123',
                legal_agreement: '1'
              }
            }

      email_taken_message = I18n.t('activerecord.errors.models.user.attributes.email.taken')
      email_taken_full_message = "#{I18n.t('activerecord.attributes.user.email')}#{email_taken_message}"

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(email_taken_message)
        expect(flash[:alert]).to include(email_taken_full_message)
        expect(second_guest.reload.unconfirmed_email).to be_nil
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'guest本登録申請で登録済みメールアドレスのエラーを1文にまとめる' do
      sign_out user
      registered_user = create(:user, email: 'guest-registered-conflict@example.com')
      guest = User.guest!
      sign_in guest
      ActionMailer::Base.deliveries.clear

      patch user_registration_path,
            params: {
              update_context: 'guest_registration',
              user: {
                email: registered_user.email,
                password: 'password123',
                password_confirmation: 'password123',
                legal_agreement: '1'
              }
            }

      email_taken_message = I18n.t('activerecord.errors.models.user.attributes.email.taken')
      email_taken_full_message = "#{I18n.t('activerecord.attributes.user.email')}#{email_taken_message}"
      unconfirmed_taken_message = I18n.t('activerecord.errors.models.user.attributes.unconfirmed_email.taken')
      document = Nokogiri::HTML(response.body)
      guest_registration_card = document.at_css('#guest-registration')
      flash_surface = document.at_css('#flash [data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(guest_registration_card.text.scan(email_taken_message).size).to eq(1)
        expect(flash[:alert]).to include(email_taken_full_message)
        expect(flash_surface.text).to include(email_taken_full_message)
        expect(response.body).not_to include(unconfirmed_taken_message)
        expect(guest.reload.unconfirmed_email).to be_nil
        expect(registered_user.reload.email).to eq('guest-registered-conflict@example.com')
        expect(ActionMailer::Base.deliveries).to be_empty
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
                password_confirmation: 'password123',
                legal_agreement: '1'
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

    it 'guest本登録の期限切れconfirmation tokenは拒否され再送後のtokenで確認できる' do
      issued_at = Time.zone.parse('2026-05-23 10:00:00')
      sign_out user
      guest = User.guest!
      fake_email = guest.email
      new_email = 'guest-expired-confirmation@example.com'
      sign_in guest
      ActionMailer::Base.deliveries.clear

      travel_to(issued_at) do
        patch user_registration_path,
              params: {
                update_context: 'guest_registration',
                user: {
                  email: new_email,
                  password: 'password123',
                  password_confirmation: 'password123',
                  legal_agreement: '1'
                }
              }
      end

      expired_token = confirmation_token_from(ActionMailer::Base.deliveries.last)

      travel_to(issued_at + 3.days + 1.minute) do
        get user_confirmation_path(confirmation_token: expired_token)
      end

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('auth.confirmations.new.title'))
        expect(response.body).to include('期限')
        expect(guest.reload).to be_guest
        expect(guest.email).to eq(fake_email)
        expect(guest.unconfirmed_email).to eq(new_email)
      end

      ActionMailer::Base.deliveries.clear
      sign_in guest

      travel_to(issued_at + 3.days + 2.minutes) do
        post user_confirmation_path,
             params: {
               user: {
                 email: new_email
               }
             }

        new_token = confirmation_token_from(ActionMailer::Base.deliveries.last)
        get user_confirmation_path(confirmation_token: new_token)
      end

      aggregate_failures do
        expect(response).to redirect_to(root_path)
        expect(guest.reload).not_to be_guest
        expect(guest.email).to eq(new_email)
        expect(guest.unconfirmed_email).to be_nil
      end
    end

    it 'guest本登録申請で同意がなければ更新しない' do
      sign_out user
      guest = User.guest!
      fake_email = guest.email
      sign_in guest
      ActionMailer::Base.deliveries.clear

      patch user_registration_path,
            params: {
              update_context: 'guest_registration',
              user: {
                email: 'guest-missing-legal@example.com',
                password: 'password123',
                password_confirmation: 'password123',
                legal_agreement: '0'
              }
            }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('activerecord.errors.models.user.attributes.legal_agreement.accepted'))
        expect(guest.reload.email).to eq(fake_email)
        expect(guest.unconfirmed_email).to be_nil
        expect(guest.legal_acceptances).to be_empty
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'guest本登録申請で同意パラメータがなければ更新しない' do
      sign_out user
      guest = User.guest!
      fake_email = guest.email
      sign_in guest
      ActionMailer::Base.deliveries.clear

      patch user_registration_path,
            params: {
              update_context: 'guest_registration',
              user: {
                email: 'guest-omitted-legal@example.com',
                password: 'password123',
                password_confirmation: 'password123'
              }
            }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('activerecord.errors.models.user.attributes.legal_agreement.accepted'))
        expect(guest.reload.email).to eq(fake_email)
        expect(guest.unconfirmed_email).to be_nil
        expect(guest.legal_acceptances).to be_empty
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'guest本登録申請のaccepted_at/version偽装はサーバー側値で上書きする' do
      sign_out user
      guest = User.guest!
      sign_in guest
      accepted_at = Time.zone.parse('2026-06-22 12:30:00')

      travel_to(accepted_at) do
        patch user_registration_path,
              params: {
                update_context: 'guest_registration',
                user: {
                  email: 'guest-spoofed-legal@example.com',
                  password: 'password123',
                  password_confirmation: 'password123',
                  legal_agreement: '1',
                  terms_accepted_at: 1.year.ago,
                  terms_version: 'client-version',
                  privacy_accepted_at: 1.year.ago,
                  privacy_version: 'client-version'
                }
              },
              headers: {
                "User-Agent" => "RSpec Guest Conversion Agent",
                "X-Request-Id" => "guest-conversion-request-id"
              }
      end

      guest.reload
      acceptances = legal_acceptances_by_type(guest)

      aggregate_failures do
        expect(response).to redirect_to(settings_security_path(anchor: 'guest-registration'))
        expect_current_legal_acceptances(guest, context: "guest_conversion", accepted_at: accepted_at)
        expect(acceptances.values.map(&:version)).not_to include('client-version')
        expect(acceptances.values).to all(have_attributes(user_agent: "RSpec Guest Conversion Agent"))
        expect(acceptances.values).to all(have_attributes(request_id: "guest-conversion-request-id"))
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
        expect(flash_message(:notice)).to eq(I18n.t('flash.users.email_change.confirmation_sent'))
        expect(user.email).to eq(old_email)
        expect(user.unconfirmed_email).to eq('reconfirmable-new@example.com')
        expect(delivered_recipients).to include('reconfirmable-new@example.com')
        expect(delivered_recipients).to include(old_email)
        expect(mail_html_body(confirmation_mail)).to include('reconfirmable-new@example.com')
        expect_mail_cta_with_fallback(confirmation_mail, I18n.t('auth.mailer.confirmation_instructions.action'))
        expect_common_mail_layout(email_changed_mail)
        expect(mail_html_body(email_changed_mail)).to include(I18n.t('auth.mailer.email_changed.title'))
        expect(mail_html_body(email_changed_mail)).not_to include(I18n.t('auth.mailer.common.fallback_url'))
      end

      follow_redirect!

      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(notice_surface).to be_present
        expect(notice_surface.text).to include(I18n.t('flash.users.email_change.confirmation_sent'))
        expect(notice_surface['data-notice-surface-auto-dismiss-value']).to eq('false')
      end

      token = confirmation_token_from(confirmation_mail)

      get user_confirmation_path(confirmation_token: token)

      aggregate_failures do
        expect(user.reload.email).to eq('reconfirmable-new@example.com')
        expect(user.unconfirmed_email).to be_nil
      end
    end

    it 'メール変更の期限切れconfirmation tokenは拒否され再送後のtokenで確認できる' do
      issued_at = Time.zone.parse('2026-05-23 10:00:00')
      old_email = user.email
      new_email = 'reconfirmable-expired@example.com'

      travel_to(issued_at) do
        patch user_registration_path,
              params: {
                update_context: 'email',
                user: {
                  email: new_email,
                  current_password: 'password'
                }
              }
      end

      confirmation_mail = ActionMailer::Base.deliveries.find { |mail| mail.to.include?(new_email) }
      expired_token = confirmation_token_from(confirmation_mail)

      travel_to(issued_at + 3.days + 1.minute) do
        get user_confirmation_path(confirmation_token: expired_token)
      end

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('auth.confirmations.new.title'))
        expect(response.body).to include('期限')
        expect(user.reload.email).to eq(old_email)
        expect(user.unconfirmed_email).to eq(new_email)
      end

      ActionMailer::Base.deliveries.clear
      sign_in user

      travel_to(issued_at + 3.days + 2.minutes) do
        post user_confirmation_path,
             params: {
               user: {
                 email: new_email
               }
             }

        new_confirmation_mail = ActionMailer::Base.deliveries.find { |mail| mail.to.include?(new_email) }
        new_token = confirmation_token_from(new_confirmation_mail)
        get user_confirmation_path(confirmation_token: new_token)
      end

      aggregate_failures do
        expect(response).to redirect_to(root_path)
        expect(user.reload.email).to eq(new_email)
        expect(user.unconfirmed_email).to be_nil
      end
    end

    it '通常ユーザーは同じ確認待ちメールアドレスへ重複変更できない' do
      first_user = user
      second_user = create(:user)

      patch user_registration_path,
            params: {
              update_context: 'email',
              user: {
                email: 'duplicate-normal-pending@example.com',
                current_password: 'password'
              }
            }

      expect(first_user.reload.unconfirmed_email).to eq('duplicate-normal-pending@example.com')

      sign_out first_user
      sign_in second_user
      ActionMailer::Base.deliveries.clear

      patch user_registration_path,
            params: {
              update_context: 'email',
              user: {
                email: 'duplicate-normal-pending@example.com',
                current_password: 'password'
              }
            }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('activerecord.errors.models.user.attributes.email.taken'))
        expect(second_user.reload.unconfirmed_email).to be_nil
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it '確認完了済みメールアドレスは別ユーザーの確認待ちメールにできない' do
      first_user = user

      patch user_registration_path,
            params: {
              update_context: 'email',
              user: {
                email: 'confirmed-email-claim@example.com',
                current_password: 'password'
              }
            }

      confirmation_mail = ActionMailer::Base.deliveries.find { |mail| mail.to.include?('confirmed-email-claim@example.com') }
      token = confirmation_token_from(confirmation_mail)

      get user_confirmation_path(confirmation_token: token)

      second_user = create(:user)
      sign_out first_user
      sign_in second_user
      ActionMailer::Base.deliveries.clear

      patch user_registration_path,
            params: {
              update_context: 'email',
              user: {
                email: 'confirmed-email-claim@example.com',
                current_password: 'password'
              }
            }

      aggregate_failures do
        expect(first_user.reload.unconfirmed_email).to be_nil
        expect(first_user.email).to eq('confirmed-email-claim@example.com')
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('activerecord.errors.models.user.attributes.email.taken'))
        expect(second_user.reload.unconfirmed_email).to be_nil
        expect(ActionMailer::Base.deliveries).to be_empty
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
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(ActionMailer::Base.deliveries.last.subject).to eq(I18n.t('devise.mailer.password_change.subject'))
      end

      password_change_mail = ActionMailer::Base.deliveries.last
      decoded_body = [
        password_change_mail.text_part&.body&.decoded,
        password_change_mail.html_part&.body&.decoded
      ].compact.join("\n")

      aggregate_failures do
        expect(password_change_mail).to be_multipart
        expect(password_change_mail.text_part).to be_present
        expect(password_change_mail.html_part).to be_present
        expect(password_change_mail.text_part.mime_type).to eq('text/plain')
        expect(password_change_mail.html_part.mime_type).to eq('text/html')
        expect(password_change_mail.attachments).to be_empty
        expect(mail_html_body(password_change_mail)).to include(I18n.t('auth.mailer.password_change.title'))
        expect(decoded_body).to include(I18n.t('auth.mailer.password_change.body'))
        expect(decoded_body).not_to include('new-password123')
        expect(decoded_body).not_to match(/token|secret|session|cookie/i)
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

    it 'settings update ignores spoofed admin param' do
      patch settings_path,
            params: {
              admin: true,
              user: {
                theme_preference: 'dark',
                admin: true
              }
            },
            as: :json

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(user.reload.theme_preference).to eq('dark')
        expect(user).not_to be_admin
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
        expect(delete_button['data-confirm-variant']).to eq('danger')
        expect(delete_button['data-confirm-icon']).to eq('delete')
        expect(delete_button['data-confirm-confirm-label']).to eq(I18n.t('notifications.item.delete'))
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

    it '税額rounding modeを更新できる' do
      patch settings_path,
            params: { user: { tax_rounding_mode: 'ceil' } },
            as: :json

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(user.reload.tax_rounding_mode).to eq('ceil')
        expect(response.parsed_body).to include(
          'ok' => true,
          'tax_rounding_mode' => 'ceil'
        )
      end
    end

    it '割引額rounding modeを更新できる' do
      patch settings_path,
            params: { user: { discount_rounding_mode: 'floor' } },
            as: :json

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(user.reload.discount_rounding_mode).to eq('floor')
        expect(response.parsed_body).to include(
          'ok' => true,
          'discount_rounding_mode' => 'floor'
        )
      end
    end

    it '不正なrounding modeは更新できない' do
      patch settings_path,
            params: { user: { tax_rounding_mode: 'bankers' } },
            as: :json

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.tax_rounding_mode).to eq('floor')
        expect(response.parsed_body).to include(
          'ok' => false,
          'message' => I18n.t('flash.settings.update_failure')
        )
      end
    end

    it 'ゲストでもrounding modeを更新でき、本登録後も設定を維持する' do
      sign_out user
      guest = User.guest!
      sign_in guest

      patch settings_path,
            params: { user: { tax_rounding_mode: 'ceil', discount_rounding_mode: 'floor' } },
            as: :json

      guest.start_guest_registration(
        email: 'rounding-guest@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        legal_agreement: '1'
      )
      guest.confirm

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(guest.reload).not_to be_guest
        expect(guest.tax_rounding_mode).to eq('ceil')
        expect(guest.discount_rounding_mode).to eq('floor')
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

    it 'updates keep receipt images setting to false' do
      patch settings_path,
            params: { user: { keep_receipt_images: false } },
            as: :json

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(user.reload.keep_receipt_images).to be(false)
        expect(response.parsed_body).to include(
          'ok' => true,
          'keep_receipt_images' => false
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
