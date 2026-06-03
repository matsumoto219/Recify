require 'rails_helper'

RSpec.describe 'Auth pages', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before do
    ActionMailer::Base.deliveries.clear
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

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(document.css('main').size).to eq(1)
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
        expect(passkey_controller).to be_present
        expect(passkey_button).to be_present
        expect(guest_form).to be_present
        expect(forgot_password_link).to be_present
        expect(sign_up_link).to be_present
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
    it 'renders registration copy through locale keys' do
      get new_user_registration_path

      document = Nokogiri::HTML(response.body)
      login_link = document.at_css("a[href='#{new_user_session_path}']")
      email_input = document.at_css('input[name="user[email]"]')
      password_input = document.at_css('input[name="user[password]"]')
      password_confirmation_input = document.at_css('input[name="user[password_confirmation]"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(document.css('main').size).to eq(1)
        expect(response.body).to include(I18n.t('auth.registrations.new.title'))
        expect(response.body).to include(I18n.t('auth.registrations.new.fields.email'))
        expect(response.body).to include(I18n.t('auth.registrations.new.terms.terms'))
        expect(response.body).to include(I18n.t('auth.registrations.new.terms.privacy'))
        expect(response.body).to include(I18n.t('auth.registrations.new.login_link'))
        expect(document.at_css("input[type='checkbox'][name='user[legal_agreement]']")).to be_present
        expect(email_input.attribute('required')).to be_present
        expect(password_input.attribute('required')).to be_present
        expect(password_confirmation_input.attribute('required')).to be_present
        expect(login_link).to be_present
      end
    end

    it 'registration creates unconfirmed user and sends confirmation mail' do
      email = 'new-confirmable-user@example.com'
      accepted_at = Time.zone.parse('2026-05-23 10:00:00')

      travel_to(accepted_at) do
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
      end

      user = User.find_by!(email: email)

      aggregate_failures do
        expect(response).to redirect_to(root_path)
        expect(flash[:notice]).to eq(I18n.t('devise.registrations.signed_up_but_unconfirmed'))
        expect(flash[:notice]).not_to eq(I18n.t('devise.confirmations.send_instructions'))
        expect(user).not_to be_confirmed
        expect(user.confirmation_token).to be_present
        expect(user.terms_accepted_at).to eq(accepted_at)
        expect(user.terms_version).to eq(User::LEGAL_TERMS_VERSION)
        expect(user.privacy_accepted_at).to eq(accepted_at)
        expect(user.privacy_version).to eq(User::LEGAL_PRIVACY_VERSION)
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(ActionMailer::Base.deliveries.last.subject).to eq(I18n.t('devise.mailer.confirmation_instructions.subject'))
        expect_mail_cta_with_fallback(ActionMailer::Base.deliveries.last, I18n.t('auth.mailer.confirmation_instructions.action'))
      end
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
        expect(response).to redirect_to(root_path)
        expect(user).not_to be_admin
      end
    end

    it 'registration without legal agreement is rejected' do
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
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'registration without legal agreement param is rejected' do
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
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    it 'registration ignores spoofed legal acceptance params' do
      email = 'spoofed-legal-acceptance@example.com'
      accepted_at = Time.zone.parse('2026-05-23 11:00:00')

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
          }
      end

      user = User.find_by!(email: email)

      aggregate_failures do
        expect(user.terms_accepted_at).to eq(accepted_at)
        expect(user.terms_version).to eq(User::LEGAL_TERMS_VERSION)
        expect(user.privacy_accepted_at).to eq(accepted_at)
        expect(user.privacy_version).to eq(User::LEGAL_PRIVACY_VERSION)
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

  describe 'GET /users/edit' do
    let(:user) { create(:user) }

    before do
      sign_in user
    end

    it '本登録ユーザーにはsettingsへの案内だけを表示する' do
      get edit_user_registration_path

      document = Nokogiri::HTML(response.body)
      registration_forms = document.css("form[action='#{user_registration_path}']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(document.css('main').size).to eq(1)
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

    it 'guestには本登録化への案内だけを表示し、内部メールを表示しない' do
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
        expect(response.body).to include(I18n.t('auth.registrations.edit.guest.title'))
        expect(response.body).to include(I18n.t('auth.registrations.edit.guest.description'))
        expect(document.at_css("a[href='#{settings_security_path(anchor: 'guest-registration')}']")).to be_present
        expect(document.at_css("a[href='#{settings_account_path}']")).to be_present
        expect(document.css("form[action='#{user_registration_path}']")).to be_empty
        expect(document.at_css('input[name="user[email]"]')).to be_nil
        expect(response.body).not_to include(fake_email)
      end
    end

    it 'registration contextを直接送っても旧更新処理を実行しない' do
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
      login_link = document.at_css("a[href='#{new_user_session_path}']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(document.css('main').size).to eq(1)
        expect(response.body).to include(I18n.t('auth.passwords.new.title'))
        expect(response.body).to include(I18n.t('auth.passwords.new.fields.email'))
        expect(response.body).to include(I18n.t('auth.passwords.new.buttons.submit'))
        expect(response.body).to include(I18n.t('auth.passwords.new.back_to_login'))
        expect(login_link).to be_present
      end
    end
  end

  describe 'GET /users/password/edit' do
    it 'renders password edit copy and keeps reset password token' do
      get edit_user_password_path(reset_password_token: reset_password_token)

      document = Nokogiri::HTML(response.body)
      login_link = document.at_css("a[href='#{new_user_session_path}']")
      password_input = document.at_css("input[type='password'][name='user[password]']")
      password_confirmation_input = document.at_css("input[type='password'][name='user[password_confirmation]']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(document.css('main').size).to eq(1)
        expect(response.body).to include(I18n.t('auth.passwords.edit.title'))
        expect(response.body).to include(I18n.t('auth.passwords.edit.fields.password'))
        expect(response.body).to include(I18n.t('auth.passwords.edit.fields.password_confirmation'))
        expect(response.body).to include(I18n.t('auth.passwords.edit.buttons.submit'))
        expect(document.at_css("input[type='hidden'][name='user[reset_password_token]']")['value']).to eq(reset_password_token)
        expect(password_input).to be_present
        expect(password_input.attribute('required')).to be_present
        expect(password_confirmation_input).to be_present
        expect(password_confirmation_input.attribute('required')).to be_present
        expect(login_link).to be_present
      end
    end
  end

  describe 'GET /users/confirmation/new' do
    it 'renders confirmation resend copy through locale keys' do
      get new_user_confirmation_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(document.css('main').size).to eq(1)
        expect(document.css('.ambient-background').size).to eq(1)
        expect(response.body).to include(I18n.t('auth.confirmations.new.title'))
        expect(response.body).to include(I18n.t('auth.confirmations.new.fields.email'))
        expect(response.body).to include(I18n.t('auth.confirmations.new.buttons.submit'))
        expect(response.body).to include(I18n.t('auth.confirmations.new.back_to_login'))
        expect(document.at_css("input[type='email'][name='user[email]']")).to be_present
        expect(document.at_css("a[href='#{new_user_session_path}']")).to be_present
      end
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
        expect(response.body).not_to include(fake_email)
        expect(response.body).to include('guest-pending-confirmation@example.com')
        expect(response.body).to include(I18n.t('auth.confirmations.new.back_to_guest_registration'))
        expect(email_input['value']).to eq('guest-pending-confirmation@example.com')
        expect(document.at_css("a[href='#{settings_security_path(anchor: 'guest-registration')}']")).to be_present
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
        expect(response.body).to include(I18n.t('auth.confirmations.new.back_to_security'))
        expect(email_input['value']).to eq('normal-pending-confirmation@example.com')
        expect(document.at_css("a[href='#{settings_security_path(anchor: 'email')}']")).to be_present
      end
    end

    it 'ログイン中でpendingがない場合はセキュリティ設定へ戻す' do
      user = create(:user)
      sign_in user

      get new_user_confirmation_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('auth.confirmations.new.back_to_security'))
        expect(document.at_css("a[href='#{settings_security_path}']")).to be_present
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
        expect(flash[:notice]).to eq(I18n.t('devise.confirmations.send_instructions'))
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(ActionMailer::Base.deliveries.last.subject).to eq(I18n.t('devise.mailer.confirmation_instructions.subject'))
        expect_mail_cta_with_fallback(ActionMailer::Base.deliveries.last, I18n.t('auth.mailer.confirmation_instructions.action'))
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

      post user_confirmation_path,
        params: {
          user: {
            email: guest.unconfirmed_email
          }
        }

      aggregate_failures do
        expect(response).to redirect_to(settings_security_path(anchor: 'guest-registration'))
        expect(flash[:notice]).to eq(I18n.t('devise.confirmations.send_instructions'))
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(ActionMailer::Base.deliveries.last.to).to include('guest-resend-confirmation@example.com')
      end
    end

    it '通常ユーザーのreconfirmation resend後はメール変更設定へ戻す' do
      user = create(:user)
      user.update!(email: 'normal-resend-confirmation@example.com')
      ActionMailer::Base.deliveries.clear
      sign_in user

      post user_confirmation_path,
        params: {
          user: {
            email: user.unconfirmed_email
          }
        }

      aggregate_failures do
        expect(response).to redirect_to(settings_security_path(anchor: 'email'))
        expect(flash[:notice]).to eq(I18n.t('devise.confirmations.send_instructions'))
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(ActionMailer::Base.deliveries.last.to).to include('normal-resend-confirmation@example.com')
      end
    end
  end

  describe 'GET /users/unlock/new' do
    it 'renders unlock resend copy through locale keys' do
      get new_user_unlock_path

      document = Nokogiri::HTML(response.body)
      login_link = document.at_css("a[href='#{new_user_session_path}']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(document.css('main').size).to eq(1)
        expect(response.body).to include(I18n.t('auth.unlocks.new.title'))
        expect(response.body).to include(I18n.t('auth.unlocks.new.fields.email'))
        expect(response.body).to include(I18n.t('auth.unlocks.new.buttons.submit'))
        expect(document.at_css("input[type='email'][name='user[email]']")).to be_present
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
  end

  describe 'POST /users/password' do
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
