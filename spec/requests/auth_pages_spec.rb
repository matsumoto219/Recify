require 'rails_helper'

RSpec.describe 'Auth pages', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before do
    ActionMailer::Base.deliveries.clear
    LegalDocuments::Sync.call
  end

  after do
    ActionMailer::Base.deliveries.clear
  end

  def with_devise_maximum_attempts(value)
    original = User.maximum_attempts
    User.maximum_attempts = value

    yield
  ensure
    User.maximum_attempts = original
  end

  def confirmation_token_from(message)
    mail_html_body(message).match(/confirmation_token=([^"'\s]+)/)[1]
  end

  def unlock_token_from(message)
    mail_html_body(message).match(/unlock_token=([^"'\s]+)/)[1]
  end

  def reset_password_token
    'reset-password-token'
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

  def expect_no_dashboard_shell
    aggregate_failures do
      expect(response.body).not_to include('id="desktop-sidebar"')
      expect(response.body).not_to include('id="dashboard-header"')
      expect(response.body).not_to include('data-controller="search"')
    end
  end

  def expect_dashboard_auth_layout(document)
    aggregate_failures do
      shell = document.at_css('.auth-page-shell')

      expect(shell).to be_present
      expect(shell['class']).to include('auth-page-shell-dashboard')
      expect(shell['class']).not_to include('min-h-screen')
      expect(shell['class']).not_to include('items-center')
      expect(document.at_css('.auth-icon-surface')).to be_nil
      expect(document.at_css('#dashboard-header')).to be_present
      expect(document.at_css('#desktop-sidebar')).to be_present
    end
  end

  def expect_standalone_auth_layout(document)
    aggregate_failures do
      shell = document.at_css('.auth-page-shell')

      expect(shell).to be_present
      expect(shell['class']).to include('auth-page-shell-standalone')
      expect(shell['class']).to include('min-h-screen')
      expect(shell['class']).to include('items-start')
      expect(shell['class']).not_to include('items-center')
      expect(document.at_css('.auth-icon-surface .brand-logo-icon')).to be_present
    end
  end

  def expect_public_header(document)
    public_header = document.at_css('#public-header')

    aggregate_failures do
      expect(public_header).to be_present
      expect(public_header.at_css('.brand-logo-full[aria-label="Recify"]')).to be_present
    end

    public_header
  end

  def password_reveal_wrapper_for(input)
    input&.ancestors&.find do |node|
      node['data-controller'].to_s.split.include?('password-reveal')
    end
  end

  def expect_password_reveal_for(input)
    wrapper = password_reveal_wrapper_for(input)
    button = wrapper&.at_css('button[data-action="password-reveal#toggle"]')
    icon = button&.at_css('[data-password-reveal-target="icon"]')

    aggregate_failures do
      expect(wrapper).to be_present
      expect(input['data-password-reveal-target']).to eq('input')
      expect(button).to be_present
      expect(button['type']).to eq('button')
      expect(button['class']).to include('password-reveal-button')
      expect(button['aria-label']).to eq(I18n.t('shared.password_reveal.show'))
      expect(button['aria-pressed']).to eq('false')
      expect(icon&.name).to eq('svg')
      expect(icon['data-animated']).to eq('true')
      expect(icon['data-revealed']).to eq('false')
      expect(icon.at_css('.password-visibility-icon-slash')).to be_present
      expect(button.at_css('.material-symbols-outlined')).to be_nil
    end
  end

  def current_legal_document(document_type)
    LegalDocument.current!(document_type, locale: :ja)
  end

  def legal_acceptances_by_type(user)
    user.legal_acceptances.index_by(&:document_type)
  end

  def expect_current_legal_acceptances(user, context:)
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
      expect(acceptances.values).to all(have_attributes(accepted_at: be_present))
    end
  end

  def enable_login_restricted_maintenance(title: '臨時メンテナンス', body: "1行目\n2行目")
    create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))
    create(:system_setting, key: 'maintenance.title', value: SystemSettings.stored_value(title))
    create(:system_setting, key: 'maintenance.body', value: SystemSettings.stored_value(body))
  end

  def with_turnstile_env(enabled:, site_key:, secret_key:)
    original_enabled = ENV["TURNSTILE_ENABLED"]
    original_site_key = ENV["TURNSTILE_SITE_KEY"]
    original_secret_key = ENV["TURNSTILE_SECRET_KEY"]

    ENV["TURNSTILE_ENABLED"] = enabled.to_s
    ENV["TURNSTILE_SITE_KEY"] = site_key
    ENV["TURNSTILE_SECRET_KEY"] = secret_key

    yield
  ensure
    ENV["TURNSTILE_ENABLED"] = original_enabled
    ENV["TURNSTILE_SITE_KEY"] = original_site_key
    ENV["TURNSTILE_SECRET_KEY"] = original_secret_key
  end

  describe 'GET /users/sign_in' do
    it 'renders login copy through locale keys and keeps guest login action' do
      get new_user_session_path

      document = Nokogiri::HTML(response.body)
      guest_form = document.at_css("form[action='#{guest_sign_in_path}']")
      forgot_password_link = document.at_css("a[href='#{new_user_password_path}']")
      sign_up_link = document.at_css("a[href='#{new_user_registration_path}']")
      email_input = document.at_css('input[name="user[email]"]')
      password_input = document.at_css('input[name="user[password]"]')
      passkey_controller = document.at_css('[data-controller~="passkey-session"]')
      passkey_button = document.at_css('[data-action="click->passkey-session#login"]')
      noscript_banner = document.at_css('noscript')
      auth_logo = document.at_css('.auth-icon-surface .brand-logo-icon')
      public_header = document.at_css('#public-header')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(document.css('main').size).to eq(1)
        expect_standalone_auth_layout(document)
        expect(public_header).to be_present
        expect(public_header.at_css('.brand-logo-full[aria-label="Recify"]')).to be_present
        expect(public_header.at_css("a[href='#{new_user_session_path}']")).to be_nil
        expect(public_header.at_css("a[href='#{new_user_registration_path}']")).to be_present
        expect(response.body).not_to include('/home_lp.css')
        expect(response.body).not_to include('data-controller="home-reveal"')
        expect(auth_logo['aria-label']).to eq('Recify')
        expect(auth_logo.at_css('.brand-logo-text')).to be_nil
        expect(response.body).to include(I18n.t('auth.sessions.title'))
        expect(noscript_banner).to be_present
        expect(noscript_banner.text).to include(I18n.t('shared.noscript.title'))
        expect(noscript_banner.text).to include(I18n.t('shared.noscript.body'))
        expect(response.body).to include(I18n.t('auth.sessions.fields.email'))
        expect(response.body).to include(I18n.t('auth.sessions.forgot_password'))
        expect(response.body).to include(I18n.t('auth.sessions.passkey.button'))
        expect(response.body).to include(I18n.t('auth.sessions.guest.button'))
        expect(response.body).to include(I18n.t('shared.footer.terms'))
        expect(response.body).to include(I18n.t('shared.footer.privacy'))
        expect(email_input['autocomplete']).to eq('username webauthn')
        expect(email_input.attribute('required')).to be_present
        expect(password_input.attribute('required')).to be_present
        expect_password_reveal_for(password_input)
        expect(passkey_controller).to be_present
        expect(passkey_button).to be_present
        expect(guest_form).to be_present
        expect(forgot_password_link).to be_present
        expect(sign_up_link).to be_present
      end
    end

    it 'Turnstile有効時はguest formにwidgetを表示し、secretはHTMLへ出さない' do
      with_turnstile_env(enabled: true, site_key: 'test_site_key', secret_key: 'test_secret_key') do
        get new_user_session_path
      end

      document = Nokogiri::HTML(response.body)
      guest_form = document.at_css("form[action='#{guest_sign_in_path}']")
      turnstile_widget = guest_form.at_css('.cf-turnstile')

      aggregate_failures do
        expect(turnstile_widget['data-controller']).to eq('turnstile')
        expect(turnstile_widget['data-turnstile-site-key-value']).to eq('test_site_key')
        expect(guest_form.at_css("script[src*='turnstile']")).to be_nil
        expect(response.body).not_to include('test_secret_key')
      end
    end

    it 'Turnstile無効時はwidgetを表示しない' do
      with_turnstile_env(enabled: false, site_key: 'test_site_key', secret_key: 'test_secret_key') do
        get new_user_session_path
      end

      expect(response.body).not_to include('cf-turnstile')
    end

    it 'login_restricted中は認証系公開画面にメンテナンスメッセージを表示しHTMLをescapeする' do
      enable_login_restricted_maintenance(
        title: '<strong>臨時メンテナンス</strong>',
        body: "<script>alert('x')</script>\n再開までお待ちください。"
      )

      [
        new_user_session_path,
        new_user_registration_path,
        new_user_password_path,
        new_user_confirmation_path
      ].each do |path|
        get path
        document = Nokogiri::HTML(response.body)

        aggregate_failures(path) do
          expect(response).to have_http_status(:success)
          expect(document.text).to include('<strong>臨時メンテナンス</strong>')
          expect(document.text).to include("<script>alert('x')</script>")
          expect(document.text).to include('再開までお待ちください。')
          expect(response.body).not_to include('<strong>臨時メンテナンス</strong>')
          expect(response.body).not_to include("<script>alert('x')</script>")
        end
      end
    end

    it 'invalid sign in shows locale-backed field errors' do
      post user_session_path,
        params: {
          user: {
            email: 'missing@example.com',
            password: 'wrong-password'
          }
        }

      email_error = "#{I18n.t('activerecord.attributes.user.email')}#{I18n.t('activerecord.errors.models.user.attributes.email.invalid')}"
      password_error = "#{I18n.t('activerecord.attributes.user.password')}#{I18n.t('activerecord.errors.models.user.attributes.password.invalid')}"

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(email_error)
        expect(response.body).to include(password_error)
        expect(flash[:alert]).to be_present
        expect(flash[:notice]).to be_nil
        expect_no_dashboard_shell
      end
    end

    it 'blank sign in shows locale-backed blank errors' do
      post user_session_path,
        params: {
          user: {
            email: '',
            password: ''
          }
        }

      email_error = "#{I18n.t('activerecord.attributes.user.email')}#{I18n.t('activerecord.errors.models.user.attributes.email.blank')}"
      password_error = "#{I18n.t('activerecord.attributes.user.password')}#{I18n.t('activerecord.errors.models.user.attributes.password.blank')}"

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(email_error)
        expect(response.body).to include(password_error)
      end
    end

    it 'successful sign in updates Trackable columns' do
      user = create(:user)

      expect do
        post user_session_path,
          params: {
            user: {
              email: user.email,
              password: 'password'
            }
          }
      end.to change { user.reload.sign_in_count }.from(0).to(1)

      aggregate_failures do
        expect(response).to have_http_status(:see_other)
        expect(flash[:notice]).to eq(I18n.t('auth.sessions.messages.signed_in'))
        expect(flash[:alert]).to be_nil
        expect(user.reload.current_sign_in_at).to be_present
        expect(user.last_sign_in_at).to be_present
        expect(user.current_sign_in_ip).to be_present
        expect(user.last_sign_in_ip).to be_present
      end
    end

    it 'unconfirmed user sign in shows unconfirmed failure' do
      user = create(:user, :unconfirmed)

      expect do
        post user_session_path,
          params: {
            user: {
              email: user.email,
              password: 'password'
            }
          }
      end.not_to change(UserSession, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(flash[:alert]).to eq(I18n.t('devise.failure.unconfirmed'))
        expect(flash[:notice]).to be_nil
        expect(response.body).to include(I18n.t('devise.failure.unconfirmed'))
        expect(response.body).not_to include(I18n.t('auth.sessions.messages.signed_in'))
        expect_no_dashboard_shell
        expect(session[:pending_second_factor]).to be_blank
        expect(session[:user_session_version]).to be_blank
        expect(session[:user_session_uid]).to be_blank
        expect(user.reload.sign_in_count).to eq(0)
      end

      get settings_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it 'lockable failure warns on last attempt and sends unlock mail when locked' do
      user = create(:user)

      with_devise_maximum_attempts(2) do
        post user_session_path,
          params: {
            user: {
              email: user.email,
              password: 'wrong-password'
            }
          }

        aggregate_failures do
          expect(response).to have_http_status(:unprocessable_content)
          expect(flash[:alert]).to eq(I18n.t('devise.failure.last_attempt'))
          expect(flash[:notice]).to be_nil
          expect_no_dashboard_shell
          expect(user.reload.failed_attempts).to eq(1)
          expect(ActionMailer::Base.deliveries).to be_empty
        end

        post user_session_path,
          params: {
            user: {
              email: user.email,
              password: 'wrong-password'
            }
          }

        aggregate_failures do
          expect(response).to have_http_status(:unprocessable_content)
          expect(flash[:alert]).to eq(I18n.t('devise.failure.locked'))
          expect(flash[:notice]).to be_nil
          expect_no_dashboard_shell
          expect(user.reload).to be_access_locked
          expect(user.unlock_token).to be_present
          expect(ActionMailer::Base.deliveries.size).to eq(1)
          expect(ActionMailer::Base.deliveries.last.subject).to eq(I18n.t('devise.mailer.unlock_instructions.subject'))
          expect_mail_cta_with_fallback(ActionMailer::Base.deliveries.last, I18n.t('auth.mailer.unlock_instructions.action'))
        end

        token = unlock_token_from(ActionMailer::Base.deliveries.last)

        get user_unlock_path(unlock_token: token)

        aggregate_failures do
          expect(response).to redirect_to(new_user_session_path)
          expect(user.reload).not_to be_access_locked
          expect(user.failed_attempts).to eq(0)
        end
      end
    end
  end

  describe 'GET /users/sign_up' do
    before do
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.success_result)
    end

    it 'renders registration copy through locale keys' do
      get new_user_registration_path

      document = Nokogiri::HTML(response.body)
      public_header = document.at_css('#public-header')
      login_link = document.at_css("a[href='#{new_user_session_path}']")
      terms_link = document.at_css("a[href='#{terms_path}']")
      privacy_link = document.at_css("a[href='#{privacy_path}']")
      legal_agreement_section = document.at_css("section[aria-label='#{I18n.t('auth.registrations.new.terms.aria_label')}']")
      legal_dialog_root = document.at_css('[data-controller~="legal-dialog"]')
      terms_dialog = document.at_css('dialog#registration-terms-dialog')
      privacy_dialog = document.at_css('dialog#registration-privacy-dialog')
      terms_full_link = terms_dialog.at_css("a[href='#{terms_path}']")
      privacy_full_link = privacy_dialog.at_css("a[href='#{privacy_path}']")
      terms_close_button = terms_dialog.at_css("button[data-action='legal-dialog#close']")
      privacy_close_button = privacy_dialog.at_css("button[data-action='legal-dialog#close']")
      email_input = document.at_css('input[name="user[email]"]')
      password_input = document.at_css('input[name="user[password]"]')
      password_confirmation_input = document.at_css('input[name="user[password_confirmation]"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(document.css('main').size).to eq(1)
        expect(public_header).to be_present
        expect(public_header.at_css('.brand-logo-full[aria-label="Recify"]')).to be_present
        expect(public_header.at_css("a[href='#{new_user_session_path}']")).to be_present
        expect(public_header.at_css("a[href='#{new_user_registration_path}']")).to be_nil
        expect(response.body).to include(I18n.t('auth.registrations.new.title'))
        expect(response.body).to include(I18n.t('auth.registrations.new.fields.email'))
        expect(response.body).to include(I18n.t('auth.registrations.new.terms.terms'))
        expect(response.body).to include(I18n.t('auth.registrations.new.terms.privacy'))
        expect(response.body).to include(I18n.t('auth.registrations.new.login_link'))
        expect(document.at_css("input[type='checkbox'][name='user[legal_agreement]']")).to be_present
        expect(terms_link&.text&.strip).to eq(I18n.t('auth.registrations.new.terms.terms'))
        expect(privacy_link&.text&.strip).to eq(I18n.t('auth.registrations.new.terms.privacy'))
        expect(terms_link['data-action']).to include('legal-dialog#open')
        expect(terms_link['data-legal-dialog-dialog-param']).to eq('terms')
        expect(privacy_link['data-action']).to include('legal-dialog#open')
        expect(privacy_link['data-legal-dialog-dialog-param']).to eq('privacy')
        expect(legal_dialog_root).to be_present
        expect(terms_dialog['data-legal-dialog-target']).to eq('dialog')
        expect(terms_dialog['aria-modal']).to eq('true')
        expect(terms_dialog['aria-labelledby']).to eq('registration-terms-dialog-title')
        expect(terms_dialog.at_css('#registration-terms-dialog-title')).to be_present
        expect(terms_close_button['aria-label']).to eq(I18n.t('legal.dialog.close'))
        expect(terms_dialog.text).to include(I18n.t('legal.dialog.summary_label'))
        expect(terms_dialog.text).to include(I18n.t('legal.dialog.terms.summary_notice'))
        expect(terms_dialog.text).to include(I18n.t('legal.dialog.terms.items').first)
        expect(terms_dialog.text).not_to include(I18n.t('legal.dialog.summary_notice'))
        expect(terms_full_link.text).to include(I18n.t('legal.dialog.open_full_terms'))
        expect(privacy_dialog['data-legal-dialog-target']).to eq('dialog')
        expect(privacy_dialog['aria-modal']).to eq('true')
        expect(privacy_dialog['aria-labelledby']).to eq('registration-privacy-dialog-title')
        expect(privacy_dialog.at_css('#registration-privacy-dialog-title')).to be_present
        expect(privacy_close_button['aria-label']).to eq(I18n.t('legal.dialog.close'))
        expect(privacy_dialog.text).to include(I18n.t('legal.dialog.summary_label'))
        expect(privacy_dialog.text).not_to include('正式本文')
        expect(privacy_dialog.text).not_to include('正式な本文は公開前')
        expect(privacy_full_link.text).to include(I18n.t('legal.dialog.open_full_privacy'))
        expect(legal_agreement_section.at_css("a[href='#']")).to be_nil
        expect(document.at_css("a[href='#']")).to be_nil
        expect(email_input['placeholder']).to eq(I18n.t('auth.registrations.new.fields.email_placeholder'))
        expect(email_input.attribute('required')).to be_present
        expect(password_input.attribute('required')).to be_present
        expect(password_confirmation_input.attribute('required')).to be_present
        expect_password_reveal_for(password_input)
        expect_password_reveal_for(password_confirmation_input)
        expect(login_link).to be_present
      end
    end

    it 'Turnstile有効時はregistration formにwidgetを表示し、secretはHTMLへ出さない' do
      with_turnstile_env(enabled: true, site_key: 'test_site_key', secret_key: 'test_secret_key') do
        get new_user_registration_path
      end

      document = Nokogiri::HTML(response.body)
      registration_form = document.at_css("form[action='#{user_registration_path}']")
      turnstile_widget = registration_form.at_css('.cf-turnstile')

      aggregate_failures do
        expect(turnstile_widget['data-controller']).to eq('turnstile')
        expect(turnstile_widget['data-turnstile-site-key-value']).to eq('test_site_key')
        expect(registration_form.at_css("script[src*='turnstile']")).to be_nil
        expect(response.body).not_to include('test_secret_key')
      end
    end

    it 'Turnstile無効時はregistration formにwidgetを表示しない' do
      with_turnstile_env(enabled: false, site_key: 'test_site_key', secret_key: 'test_secret_key') do
        get new_user_registration_path
      end

      expect(response.body).not_to include('cf-turnstile')
    end

    it 'registration creates unconfirmed user and sends confirmation mail' do
      email = 'new-confirmable-user@example.com'

      expect do
        post user_registration_path,
          params: {
            user: {
              email: email,
              password: 'password',
              password_confirmation: 'password',
              legal_agreement: '1'
            }
          }
      end.to change(User, :count).by(1)

      user = User.find_by!(email: email)

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(flash_message(:notice)).to eq(I18n.t('devise.registrations.signed_up_but_unconfirmed'))
        expect(flash_message(:notice)).not_to eq(I18n.t('devise.confirmations.send_instructions'))
        expect(user).not_to be_confirmed
        expect(user.confirmation_token).to be_present
        expect_current_legal_acceptances(user, context: "signup")
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(ActionMailer::Base.deliveries.last.subject).to eq(I18n.t('devise.mailer.confirmation_instructions.subject'))
        expect_mail_cta_with_fallback(ActionMailer::Base.deliveries.last, I18n.t('auth.mailer.confirmation_instructions.action'))
      end
    end

    it 'confirmationが次アクションになる登録完了flashは自動で閉じない' do
      email = 'manual-dismiss-confirmable-user@example.com'

      post user_registration_path,
        params: {
          user: {
            email: email,
            password: 'password',
            password_confirmation: 'password',
            legal_agreement: '1'
          }
        }

      follow_redirect!

      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(notice_surface).to be_present
        expect(notice_surface.text).to include(I18n.t('devise.registrations.signed_up_but_unconfirmed'))
        expect(notice_surface['data-notice-surface-auto-dismiss-value']).to eq('false')
        expect(notice_surface.at_css('button[data-action="click->notice-surface#close"]')).to be_present
      end
    end

    it 'current法務文書が未同期の場合はuserを作成せず案内を表示する' do
      LegalDocument.delete_all

      expect do
        post user_registration_path,
          params: {
            user: {
              email: 'legal-documents-missing@example.com',
              password: 'password',
              password_confirmation: 'password',
              legal_agreement: '1'
            }
          }
      end.not_to change(User, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.legal_documents.unavailable'))
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'Turbo送信でもcurrent法務文書未同期時はHTMLの案内画面を返す' do
      LegalDocument.delete_all

      expect do
        post user_registration_path,
          params: {
            user: {
              email: 'turbo-legal-documents-missing@example.com',
              password: 'password',
              password_confirmation: 'password',
              legal_agreement: '1'
            }
          },
          headers: {
            'ACCEPT' => "#{Mime[:turbo_stream]}, #{Mime[:html]}, application/xhtml+xml"
          }
      end.not_to change(User, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.media_type).to eq(Mime[:html].to_s)
        expect(response.body).to include(I18n.t('flash.legal_documents.unavailable'))
        expect(response.body).to include('registration-form-title')
        expect(response.body).to include(I18n.t('auth.registrations.new.submit'))
        expect(response.body).not_to include('<turbo-stream')
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'login_restricted中は通常登録を拒否し、user作成と確認メール送信をしない' do
      create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))
      expect(BotProtection).not_to receive(:verify_turnstile)

      expect do
        post user_registration_path,
          params: {
            user: {
              email: 'maintenance-registration@example.com',
              password: 'password',
              password_confirmation: 'password',
              legal_agreement: '1'
            }
          }
      end.not_to change(User, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('shared.maintenance_mode.body'))
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'Turnstile有効時にtokenなしならuserを作成せず確認メールを送らない' do
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.failure_result("turnstile_token_missing"))

      expect do
        post user_registration_path,
          params: {
            user: {
              email: 'turnstile-missing-registration@example.com',
              password: 'password',
              password_confirmation: 'password',
              legal_agreement: '1'
            }
          }
      end.not_to change(User, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.bot_protection.verification_failed'))
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'Turnstile検証失敗時はuserを作成しない' do
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.failure_result("turnstile_verification_failed"))

      expect do
        post user_registration_path,
          params: {
            "cf-turnstile-response" => "invalid-token",
            user: {
              email: 'turnstile-failed-registration@example.com',
              password: 'password',
              password_confirmation: 'password',
              legal_agreement: '1'
            }
          }
      end.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'Turnstile検証成功時は既存registration flowを維持する' do
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.success_result)

      expect do
        post user_registration_path,
          params: {
            "cf-turnstile-response" => "valid-token",
            user: {
              email: 'turnstile-success-registration@example.com',
              password: 'password',
              password_confirmation: 'password',
              legal_agreement: '1'
            }
          }
      end.to change(User, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(flash_message(:notice)).to eq(I18n.t('devise.registrations.signed_up_but_unconfirmed'))
        expect(ActionMailer::Base.deliveries.size).to eq(1)
      end
    end

    it 'Turnstile無効時は既存registration flowを維持する' do
      allow(BotProtection).to receive(:verify_turnstile).and_call_original

      with_turnstile_env(enabled: false, site_key: 'test_site_key', secret_key: 'test_secret_key') do
        expect do
          post user_registration_path,
            params: {
              user: {
                email: 'turnstile-disabled-registration@example.com',
                password: 'password',
                password_confirmation: 'password',
                legal_agreement: '1'
              }
            }
        end.to change(User, :count).by(1)
      end

      expect(response).to redirect_to(new_user_session_path)
    end

    it 'registration ignores spoofed admin param' do
      email = 'spoofed-admin-registration@example.com'

      expect do
        post user_registration_path,
          params: {
            user: {
              email: email,
              password: 'password',
              password_confirmation: 'password',
              legal_agreement: '1',
              admin: true
            }
          }
      end.to change(User, :count).by(1)

      user = User.find_by!(email: email)

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(user).not_to be_admin
      end
    end

    it 'registration without legal agreement is rejected' do
      legal_acceptance_count = LegalAcceptance.count

      expect do
        post user_registration_path,
          params: {
            user: {
              email: 'missing-legal-agreement@example.com',
              password: 'password',
              password_confirmation: 'password',
              legal_agreement: '0'
            }
          }
      end.not_to change(User, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('activerecord.errors.models.user.attributes.legal_agreement.accepted'))
        expect(LegalAcceptance.count).to eq(legal_acceptance_count)
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'registration without legal agreement param is rejected' do
      legal_acceptance_count = LegalAcceptance.count

      expect do
        post user_registration_path,
          params: {
            user: {
              email: 'omitted-legal-agreement@example.com',
              password: 'password',
              password_confirmation: 'password'
            }
          }
      end.not_to change(User, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('activerecord.errors.models.user.attributes.legal_agreement.accepted'))
        expect(LegalAcceptance.count).to eq(legal_acceptance_count)
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'registration ignores spoofed legal acceptance params' do
      email = 'spoofed-legal-acceptance@example.com'
      accepted_at = Time.zone.parse('2026-06-22 12:00:00')

      travel_to(accepted_at) do
        post user_registration_path,
          params: {
            user: {
              email: email,
              password: 'password',
              password_confirmation: 'password',
              legal_agreement: '1',
              terms_accepted_at: 1.year.ago,
              terms_version: 'client-version',
              privacy_accepted_at: 1.year.ago,
              privacy_version: 'client-version'
            }
          },
          headers: {
            "User-Agent" => "RSpec Signup Agent",
            "X-Request-Id" => "signup-request-id"
          }
      end

      user = User.find_by!(email: email)
      acceptances = legal_acceptances_by_type(user)

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect_current_legal_acceptances(user, context: "signup")
        expect(acceptances.values.map(&:version)).not_to include('client-version')
        expect(acceptances.values).to all(have_attributes(accepted_at: accepted_at))
        expect(acceptances.values).to all(have_attributes(user_agent: "RSpec Signup Agent"))
        expect(acceptances.values).to all(have_attributes(request_id: "signup-request-id"))
      end
    end

    it 'confirmation link confirms the registered user' do
      email = 'confirm-link-user@example.com'
      post user_registration_path,
        params: {
          user: {
            email: email,
            password: 'password',
            password_confirmation: 'password',
            legal_agreement: '1'
          }
        }

      token = confirmation_token_from(ActionMailer::Base.deliveries.last)

      get user_confirmation_path(confirmation_token: token)

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(User.find_by!(email: email)).to be_confirmed
      end
    end

    it 'confirmation link confirms the registered user within the confirmation period' do
      issued_at = Time.zone.parse('2026-05-23 10:00:00')
      email = 'confirm-link-within-period@example.com'

      travel_to(issued_at) do
        post user_registration_path,
          params: {
            user: {
              email: email,
              password: 'password',
              password_confirmation: 'password',
              legal_agreement: '1'
            }
          }
      end

      token = confirmation_token_from(ActionMailer::Base.deliveries.last)

      travel_to(issued_at + 3.days - 1.minute) do
        get user_confirmation_path(confirmation_token: token)
      end

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(User.find_by!(email: email)).to be_confirmed
      end
    end

    it 'expired confirmation token is rejected and resend issues a usable token' do
      issued_at = Time.zone.parse('2026-05-23 10:00:00')
      email = 'expired-confirmation@example.com'

      travel_to(issued_at) do
        post user_registration_path,
          params: {
            user: {
              email: email,
              password: 'password',
              password_confirmation: 'password',
              legal_agreement: '1'
            }
          }
      end

      user = User.find_by!(email: email)
      expired_token = confirmation_token_from(ActionMailer::Base.deliveries.last)

      travel_to(issued_at + 3.days + 1.minute) do
        get user_confirmation_path(confirmation_token: expired_token)
      end

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('auth.confirmations.new.title'))
        expect(response.body).to include('期限')
        expect(user.reload).not_to be_confirmed
      end

      ActionMailer::Base.deliveries.clear

      travel_to(issued_at + 3.days + 2.minutes) do
        post user_confirmation_path,
          params: {
            user: {
              email: email
            }
          }

        new_token = confirmation_token_from(ActionMailer::Base.deliveries.last)
        get user_confirmation_path(confirmation_token: new_token)
      end

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(user.reload).to be_confirmed
      end
    end
  end

  describe 'GET /users/edit fallback guide page' do
    let(:user) { create(:user) }

    before do
      sign_in user
    end

    it '本登録ユーザーにはsettingsへの案内fallbackだけを表示する' do
      get edit_user_registration_path

      document = Nokogiri::HTML(response.body)
      registration_forms = document.css("form[action='#{user_registration_path}']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(document.css('main').size).to eq(1)
        expect_dashboard_auth_layout(document)
        expect(response.body).to include(I18n.t('auth.registrations.edit.title'))
        expect(response.body).to include(I18n.t('auth.registrations.edit.normal.title'))
        expect(response.body).to include(I18n.t('auth.registrations.edit.normal.description'))
        expect(document.at_css("a[href='#{settings_security_path}']")).to be_present
        expect(document.at_css("a[href='#{settings_account_path}']")).to be_present
        expect(registration_forms).to be_empty
        expect(document.at_css('input[name="user[email]"]')).to be_nil
        expect(document.at_css('input[name="user[password]"]')).to be_nil
        expect(document.at_css('input[name="user[current_password]"]')).to be_nil
      end
    end

    it 'guestには本登録化への案内fallbackだけを表示し、内部メールを表示しない' do
      sign_out user
      guest = User.guest!
      fake_email = guest.email
      sign_in guest

      get edit_user_registration_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(guest.reload.name).to be_blank
        expect(document.css('main').size).to eq(1)
        expect_dashboard_auth_layout(document)
        expect(response.body).to include(I18n.t('auth.registrations.edit.guest.title'))
        expect(response.body).to include(I18n.t('auth.registrations.edit.guest.description'))
        expect(document.at_css("a[href='#{settings_security_path(anchor: 'guest-registration')}']")).to be_present
        expect(document.at_css("a[href='#{settings_account_path}']")).to be_present
        expect(document.css("form[action='#{user_registration_path}']")).to be_empty
        expect(document.at_css('input[name="user[email]"]')).to be_nil
        expect(response.body).not_to include(fake_email)
      end
    end

    it 'registration contextを直接送っても旧Devise registration edit更新処理を実行しない' do
      original_email = user.email
      original_encrypted_password = user.encrypted_password

      put user_registration_path,
          params: {
            update_context: 'registration',
            user: {
              email: 'legacy-registration@example.com',
              password: 'new-password123',
              password_confirmation: 'new-password123',
              current_password: 'password'
            }
          }

      aggregate_failures do
        expect(response).to redirect_to(settings_security_path)
        expect(flash[:alert]).to eq(I18n.t('flash.users.unsupported_update_context'))
        expect(user.reload.email).to eq(original_email)
        expect(user.unconfirmed_email).to be_nil
        expect(user.encrypted_password).to eq(original_encrypted_password)
        expect(user).to be_valid_password('password')
        expect(user).not_to be_valid_password('new-password123')
      end
    end

    it '未知のupdate contextを直接送っても更新しない' do
      original_name = user.name
      original_email = user.email
      original_encrypted_password = user.encrypted_password

      put user_registration_path,
          params: {
            update_context: 'unknown',
            user: {
              name: 'Unknown Context',
              email: 'unknown-context@example.com',
              password: 'new-password123',
              password_confirmation: 'new-password123',
              current_password: 'password'
            }
          }

      aggregate_failures do
        expect(response).to redirect_to(settings_security_path)
        expect(flash[:alert]).to eq(I18n.t('flash.users.unsupported_update_context'))
        expect(user.reload.name).to eq(original_name)
        expect(user.email).to eq(original_email)
        expect(user.unconfirmed_email).to be_nil
        expect(user.encrypted_password).to eq(original_encrypted_password)
        expect(user).not_to be_valid_password('new-password123')
      end
    end
  end

  describe 'DELETE /users/sign_out' do
    let(:user) { create(:user) }

    it 'keeps sign out unavailable over GET' do
      expect do
        Rails.application.routes.recognize_path(destroy_user_session_path, method: :get)
      end.to raise_error(ActionController::RoutingError)
    end

    it 'signs out through the DELETE route' do
      sign_in user

      delete destroy_user_session_path

      expect(response).to have_http_status(:see_other)
    end
  end

  describe 'GET /users/password/new' do
    it 'renders password reset copy through locale keys' do
      get new_user_password_path

      document = Nokogiri::HTML(response.body)
      public_header = expect_public_header(document)
      login_link = document.at_css("a[href='#{new_user_session_path}']")
      email_input = document.at_css('input[name="user[email]"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(document.css('main').size).to eq(1)
        expect_standalone_auth_layout(document)
        expect(public_header.at_css("a[href='#{new_user_session_path}']")).to be_present
        expect(public_header.at_css("a[href='#{new_user_registration_path}']")).to be_present
        expect(response.body).to include(I18n.t('auth.passwords.new.title'))
        expect(response.body).to include(I18n.t('auth.passwords.new.fields.email'))
        expect(response.body).to include(I18n.t('auth.passwords.new.buttons.submit'))
        expect(response.body).to include(I18n.t('auth.passwords.new.back_to_login'))
        expect(email_input['placeholder']).to eq(I18n.t('auth.passwords.new.fields.email_placeholder'))
        expect(login_link).to be_present
      end
    end

    it 'Turnstile有効時はpassword reset formにwidgetを表示し、secretはHTMLへ出さない' do
      with_turnstile_env(enabled: true, site_key: 'test_site_key', secret_key: 'test_secret_key') do
        get new_user_password_path
      end

      document = Nokogiri::HTML(response.body)
      password_form = document.at_css("form[action='#{user_password_path}']")
      turnstile_widget = password_form.at_css('.cf-turnstile')

      aggregate_failures do
        expect(turnstile_widget['data-controller']).to eq('turnstile')
        expect(turnstile_widget['data-turnstile-site-key-value']).to eq('test_site_key')
        expect(password_form.at_css("script[src*='turnstile']")).to be_nil
        expect(response.body).not_to include('test_secret_key')
      end
    end

    it 'Turnstile無効時はpassword reset formにwidgetを表示しない' do
      with_turnstile_env(enabled: false, site_key: 'test_site_key', secret_key: 'test_secret_key') do
        get new_user_password_path
      end

      expect(response.body).not_to include('cf-turnstile')
    end
  end

  describe 'GET /users/password/edit reset-token page' do
    it 'renders password reset-token edit copy and keeps reset password token' do
      get edit_user_password_path(reset_password_token: reset_password_token)

      document = Nokogiri::HTML(response.body)
      public_header = expect_public_header(document)
      login_link = document.at_css("a[href='#{new_user_session_path}']")
      password_input = document.at_css("input[type='password'][name='user[password]']")
      password_confirmation_input = document.at_css("input[type='password'][name='user[password_confirmation]']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(document.css('main').size).to eq(1)
        expect(public_header.at_css("a[href='#{new_user_session_path}']")).to be_present
        expect(public_header.at_css("a[href='#{new_user_registration_path}']")).to be_present
        expect(response.body).to include(I18n.t('auth.passwords.edit.title'))
        expect(response.body).to include(I18n.t('auth.passwords.edit.fields.password'))
        expect(response.body).to include(I18n.t('auth.passwords.edit.fields.password_confirmation'))
        expect(response.body).to include(I18n.t('auth.passwords.edit.buttons.submit'))
        expect(document.at_css("input[type='hidden'][name='user[reset_password_token]']")['value']).to eq(reset_password_token)
        expect(password_input).to be_present
        expect(password_input.attribute('required')).to be_present
        expect(password_confirmation_input).to be_present
        expect(password_confirmation_input.attribute('required')).to be_present
        expect_password_reveal_for(password_input)
        expect_password_reveal_for(password_confirmation_input)
        expect(login_link).to be_present
      end
    end
  end

  describe 'GET /users/confirmation/new' do
    before do
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.success_result)
    end

    it 'renders confirmation resend copy through locale keys' do
      get new_user_confirmation_path

      document = Nokogiri::HTML(response.body)
      public_header = expect_public_header(document)
      email_input = document.at_css("input[type='email'][name='user[email]']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(document.css('main').size).to eq(1)
        expect(document.css('.ambient-background').size).to eq(1)
        expect_standalone_auth_layout(document)
        expect(public_header.at_css("a[href='#{new_user_session_path}']")).to be_present
        expect(public_header.at_css("a[href='#{new_user_registration_path}']")).to be_present
        expect(response.body).to include(I18n.t('auth.confirmations.new.title'))
        expect(response.body).to include(I18n.t('auth.confirmations.new.fields.email'))
        expect(response.body).to include(I18n.t('auth.confirmations.new.buttons.submit'))
        expect(response.body).to include(I18n.t('auth.confirmations.new.back_to_login'))
        expect(email_input).to be_present
        expect(email_input['placeholder']).to eq(I18n.t('auth.confirmations.new.fields.email_placeholder'))
        expect(document.at_css("a[href='#{new_user_session_path}']")).to be_present
      end
    end

    it 'Turnstile有効時はconfirmation resend formにwidgetを表示し、secretはHTMLへ出さない' do
      with_turnstile_env(enabled: true, site_key: 'test_site_key', secret_key: 'test_secret_key') do
        get new_user_confirmation_path
      end

      document = Nokogiri::HTML(response.body)
      confirmation_form = document.at_css("form[action='#{user_confirmation_path}']")
      turnstile_widget = confirmation_form.at_css('.cf-turnstile')

      aggregate_failures do
        expect(turnstile_widget['data-controller']).to eq('turnstile')
        expect(turnstile_widget['data-turnstile-site-key-value']).to eq('test_site_key')
        expect(confirmation_form.at_css("script[src*='turnstile']")).to be_nil
        expect(response.body).not_to include('test_secret_key')
      end
    end

    it 'Turnstile無効時はconfirmation resend formにwidgetを表示しない' do
      with_turnstile_env(enabled: false, site_key: 'test_site_key', secret_key: 'test_secret_key') do
        get new_user_confirmation_path
      end

      expect(response.body).not_to include('cf-turnstile')
    end

    it 'guest本登録申請中は内部メールを出さず本登録設定へ戻す' do
      guest = User.guest!
      fake_email = guest.email
      guest.start_guest_registration(
        email: 'guest-pending-confirmation@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        legal_agreement: '1'
      )
      ActionMailer::Base.deliveries.clear
      sign_in guest

      get new_user_confirmation_path

      document = Nokogiri::HTML(response.body)
      email_input = document.at_css("input[type='email'][name='user[email]']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.css('.ambient-background').size).to eq(1)
        expect_dashboard_auth_layout(document)
        expect(response.body).not_to include(fake_email)
        expect(response.body).to include('guest-pending-confirmation@example.com')
        expect(response.body).to include(I18n.t('auth.confirmations.new.back_to_guest_registration'))
        expect(email_input['value']).to eq('guest-pending-confirmation@example.com')
        expect(document.at_css("a[href='#{settings_security_path(anchor: 'guest-registration')}']")).to be_present
        expect(response.body).not_to include('cf-turnstile')
      end
    end

    it '通常ユーザーのreconfirmation中はメール変更設定へ戻す' do
      user = create(:user)
      user.update!(email: 'normal-pending-confirmation@example.com')
      ActionMailer::Base.deliveries.clear
      sign_in user

      get new_user_confirmation_path

      document = Nokogiri::HTML(response.body)
      email_input = document.at_css("input[type='email'][name='user[email]']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.css('.ambient-background').size).to eq(1)
        expect_dashboard_auth_layout(document)
        expect(response.body).to include(I18n.t('auth.confirmations.new.back_to_security'))
        expect(email_input['value']).to eq('normal-pending-confirmation@example.com')
        expect(document.at_css("a[href='#{settings_security_path(anchor: 'email')}']")).to be_present
        expect(response.body).not_to include('cf-turnstile')
      end
    end

    it 'guest本登録中のconfirmation resendは現在の確認待ちメール以外へ送らない' do
      guest = User.guest!
      guest.start_guest_registration(
        email: 'guest-resend-target@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        legal_agreement: '1'
      )
      confirmed_user = create(:user, email: 'guest-resend-confirmed@example.com')
      unconfirmed_user = create(:user, :unconfirmed, email: 'guest-resend-unconfirmed@example.com')
      original_confirmed_at = confirmed_user.confirmed_at
      original_unconfirmed_sent_at = unconfirmed_user.confirmation_sent_at
      sign_in guest

      [
        confirmed_user.email,
        unconfirmed_user.email,
        'guest-resend-unused@example.com'
      ].each do |requested_email|
        ActionMailer::Base.deliveries.clear

        post user_confirmation_path,
          params: {
            user: {
              email: requested_email
            }
          }

        aggregate_failures "requested #{requested_email}" do
          expect(response).to redirect_to(settings_security_path(anchor: 'guest-registration'))
          expect(flash[:alert]).to eq(I18n.t('flash.users.confirmation_resend.email_mismatch'))
          expect(ActionMailer::Base.deliveries).to be_empty
          expect(guest.reload).to be_guest
          expect(guest.unconfirmed_email).to eq('guest-resend-target@example.com')
          expect(confirmed_user.reload.confirmed_at).to eq(original_confirmed_at)
          expect(confirmed_user.unconfirmed_email).to be_nil
          expect(unconfirmed_user.reload.confirmation_sent_at).to eq(original_unconfirmed_sent_at)
          expect(unconfirmed_user.confirmed_at).to be_nil
        end
      end
    end

    it 'guest本登録中のconfirmation resendは現在の確認待ちメールへだけ送る' do
      guest = User.guest!
      guest.start_guest_registration(
        email: 'guest-resend-current@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        legal_agreement: '1'
      )
      sign_in guest
      ActionMailer::Base.deliveries.clear

      post user_confirmation_path,
        params: {
          user: {
            email: 'guest-resend-current@example.com'
          }
        }

      aggregate_failures do
        expect(response).to redirect_to(settings_security_path(anchor: 'guest-registration'))
        expect(flash_message(:notice)).to eq(I18n.t('devise.confirmations.send_instructions'))
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(ActionMailer::Base.deliveries.last.to).to include('guest-resend-current@example.com')
      end
    end

    it 'ログイン中でpendingがない場合はセキュリティ設定へ戻す' do
      user = create(:user)
      sign_in user

      get new_user_confirmation_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect_dashboard_auth_layout(document)
        expect(response.body).to include(I18n.t('auth.confirmations.new.back_to_security'))
        expect(document.at_css("a[href='#{settings_security_path}']")).to be_present
        expect(response.body).not_to include('cf-turnstile')
      end
    end

    it '未ログインのconfirmation resendは確認メールを送りログインへ戻す' do
      user = create(:user, :unconfirmed)
      ActionMailer::Base.deliveries.clear

      post user_confirmation_path,
        params: {
          user: {
            email: user.email
          }
        }

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(flash_message(:notice)).to eq(I18n.t('devise.confirmations.send_instructions'))
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(ActionMailer::Base.deliveries.last.subject).to eq(I18n.t('devise.mailer.confirmation_instructions.subject'))
        expect_mail_cta_with_fallback(ActionMailer::Base.deliveries.last, I18n.t('auth.mailer.confirmation_instructions.action'))
      end
    end

    it 'confirmation resend後の確認メール送信flashは自動で閉じない' do
      user = create(:user, :unconfirmed)
      ActionMailer::Base.deliveries.clear

      post user_confirmation_path,
        params: {
          user: {
            email: user.email
          }
        }

      follow_redirect!

      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(notice_surface).to be_present
        expect(notice_surface.text).to include(I18n.t('devise.confirmations.send_instructions'))
        expect(notice_surface['data-notice-surface-auto-dismiss-value']).to eq('false')
      end
    end

    it 'login_restricted中はconfirmation resendを拒否し、確認メールを送らない' do
      user = create(:user, :unconfirmed)
      create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))
      ActionMailer::Base.deliveries.clear
      expect(BotProtection).not_to receive(:verify_turnstile)

      post user_confirmation_path,
        params: {
          user: {
            email: user.email
          }
        }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('shared.maintenance_mode.body'))
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'Turnstile有効時にtokenなしならconfirmation mailを送らない' do
      user = create(:user, :unconfirmed)
      ActionMailer::Base.deliveries.clear
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.failure_result("turnstile_token_missing"))

      post user_confirmation_path,
        params: {
          user: {
            email: user.email
          }
        }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.bot_protection.verification_failed'))
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'Turnstile検証失敗時はconfirmation mailを送らない' do
      user = create(:user, :unconfirmed)
      ActionMailer::Base.deliveries.clear
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.failure_result("turnstile_verification_failed"))

      post user_confirmation_path,
        params: {
          "cf-turnstile-response" => "invalid-token",
          user: {
            email: user.email
          }
        }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'Turnstile検証成功時は既存confirmation resend flowを維持する' do
      user = create(:user, :unconfirmed)
      ActionMailer::Base.deliveries.clear
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.success_result)

      post user_confirmation_path,
        params: {
          "cf-turnstile-response" => "valid-token",
          user: {
            email: user.email
          }
        }

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(ActionMailer::Base.deliveries.size).to eq(1)
      end
    end

    it 'Turnstile無効時は既存confirmation resend flowを維持する' do
      user = create(:user, :unconfirmed)
      ActionMailer::Base.deliveries.clear
      allow(BotProtection).to receive(:verify_turnstile).and_call_original

      with_turnstile_env(enabled: false, site_key: 'test_site_key', secret_key: 'test_secret_key') do
        post user_confirmation_path,
          params: {
            user: {
              email: user.email
            }
          }
      end

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(ActionMailer::Base.deliveries.size).to eq(1)
      end
    end

    it 'guest本登録申請中のconfirmation resend後は本登録設定へ戻す' do
      guest = User.guest!
      guest.start_guest_registration(
        email: 'guest-resend-confirmation@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        legal_agreement: '1'
      )
      ActionMailer::Base.deliveries.clear
      sign_in guest
      expect(BotProtection).not_to receive(:verify_turnstile)

      post user_confirmation_path,
        params: {
          user: {
            email: guest.unconfirmed_email
          }
        }

      aggregate_failures do
        expect(response).to redirect_to(settings_security_path(anchor: 'guest-registration'))
        expect(flash_message(:notice)).to eq(I18n.t('devise.confirmations.send_instructions'))
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(ActionMailer::Base.deliveries.last.to).to include('guest-resend-confirmation@example.com')
      end
    end

    it '通常ユーザーのreconfirmation resend後はメール変更設定へ戻す' do
      user = create(:user)
      user.update!(email: 'normal-resend-confirmation@example.com')
      ActionMailer::Base.deliveries.clear
      sign_in user
      expect(BotProtection).not_to receive(:verify_turnstile)

      post user_confirmation_path,
        params: {
          user: {
            email: user.unconfirmed_email
          }
        }

      aggregate_failures do
        expect(response).to redirect_to(settings_security_path(anchor: 'email'))
        expect(flash_message(:notice)).to eq(I18n.t('devise.confirmations.send_instructions'))
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(ActionMailer::Base.deliveries.last.to).to include('normal-resend-confirmation@example.com')
      end
    end
  end

  describe 'GET /users/unlock/new' do
    it 'renders unlock resend copy through locale keys' do
      get new_user_unlock_path

      document = Nokogiri::HTML(response.body)
      public_header = expect_public_header(document)
      login_link = document.at_css("a[href='#{new_user_session_path}']")
      email_input = document.at_css("input[type='email'][name='user[email]']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(document.css('main').size).to eq(1)
        expect(public_header.at_css("a[href='#{new_user_session_path}']")).to be_present
        expect(public_header.at_css("a[href='#{new_user_registration_path}']")).to be_present
        expect(response.body).to include(I18n.t('auth.unlocks.new.title'))
        expect(response.body).to include(I18n.t('auth.unlocks.new.fields.email'))
        expect(response.body).to include(I18n.t('auth.unlocks.new.buttons.submit'))
        expect(email_input).to be_present
        expect(email_input['placeholder']).to eq(I18n.t('auth.unlocks.new.fields.email_placeholder'))
        expect(login_link).to be_present
      end
    end

    it 'unlock resend sends unlock mail' do
      user = create(:user)
      user.lock_access!(send_instructions: false)
      ActionMailer::Base.deliveries.clear

      post user_unlock_path,
        params: {
          user: {
            email: user.email
          }
        }

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(ActionMailer::Base.deliveries.last.subject).to eq(I18n.t('devise.mailer.unlock_instructions.subject'))
        expect_mail_cta_with_fallback(ActionMailer::Base.deliveries.last, I18n.t('auth.mailer.unlock_instructions.action'))
      end
    end

    it 'unlock resend後の復旧メール送信flashは自動で閉じない' do
      user = create(:user)
      user.lock_access!(send_instructions: false)
      ActionMailer::Base.deliveries.clear

      post user_unlock_path,
        params: {
          user: {
            email: user.email
          }
        }

      follow_redirect!

      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(notice_surface).to be_present
        expect(notice_surface.text).to include(I18n.t('devise.unlocks.send_instructions'))
        expect(notice_surface['data-notice-surface-auto-dismiss-value']).to eq('false')
      end
    end
  end

  describe 'POST /users/password' do
    before do
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.success_result)
    end

    it 'password reset sends reset instructions' do
      user = create(:user)

      post user_password_path,
        params: {
          user: {
            email: user.email
          }
        }

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(ActionMailer::Base.deliveries.last.subject).to eq(I18n.t('devise.mailer.reset_password_instructions.subject'))
        expect_mail_cta_with_fallback(ActionMailer::Base.deliveries.last, I18n.t('auth.mailer.reset_password_instructions.action'))
      end
    end

    it 'password reset後の再設定メール送信flashは自動で閉じない' do
      user = create(:user)

      post user_password_path,
        params: {
          user: {
            email: user.email
          }
        }

      follow_redirect!

      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(notice_surface).to be_present
        expect(notice_surface.text).to include(I18n.t('devise.passwords.send_instructions'))
        expect(notice_surface['data-notice-surface-auto-dismiss-value']).to eq('false')
      end
    end

    it 'login_restricted中はpassword resetを拒否し、reset password mailを送らない' do
      user = create(:user)
      create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))
      expect(BotProtection).not_to receive(:verify_turnstile)

      post user_password_path,
        params: {
          user: {
            email: user.email
          }
        }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('shared.maintenance_mode.body'))
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'Turnstile有効時にtokenなしならreset password mailを送らない' do
      user = create(:user)
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.failure_result("turnstile_token_missing"))

      post user_password_path,
        params: {
          user: {
            email: user.email
          }
        }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.bot_protection.verification_failed'))
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'Turnstile検証失敗時はreset password mailを送らない' do
      user = create(:user)
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.failure_result("turnstile_verification_failed"))

      post user_password_path,
        params: {
          "cf-turnstile-response" => "invalid-token",
          user: {
            email: user.email
          }
        }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'Turnstile検証成功時は既存password reset flowを維持する' do
      user = create(:user)
      allow(BotProtection).to receive(:verify_turnstile).and_return(BotProtection.success_result)

      post user_password_path,
        params: {
          "cf-turnstile-response" => "valid-token",
          user: {
            email: user.email
          }
        }

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(ActionMailer::Base.deliveries.size).to eq(1)
      end
    end

    it 'Turnstile無効時は既存password reset flowを維持する' do
      user = create(:user)
      allow(BotProtection).to receive(:verify_turnstile).and_call_original

      with_turnstile_env(enabled: false, site_key: 'test_site_key', secret_key: 'test_secret_key') do
        post user_password_path,
          params: {
            user: {
              email: user.email
            }
          }
      end

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(ActionMailer::Base.deliveries.size).to eq(1)
      end
    end

    it 'guestの内部メール宛にはpassword reset mailを送らない' do
      guest = User.guest!

      post user_password_path,
        params: {
          user: {
            email: guest.email
          }
        }

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end
  end
end
