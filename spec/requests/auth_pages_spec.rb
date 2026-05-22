require 'rails_helper'

RSpec.describe 'Auth pages', type: :request do
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
    message.body.encoded.match(/confirmation_token=([^"'\s]+)/)[1]
  end

  def unlock_token_from(message)
    message.body.encoded.match(/unlock_token=([^"'\s]+)/)[1]
  end

  describe 'GET /users/sign_in' do
    it 'renders login copy through locale keys and keeps guest login action' do
      get new_user_session_path

      document = Nokogiri::HTML(response.body)
      guest_form = document.at_css("form[action='#{guest_sign_in_path}']")
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
        expect(response.body).to include(I18n.t('auth.sessions.guest.button'))
        expect(response.body).to include(I18n.t('shared.footer.terms'))
        expect(response.body).to include(I18n.t('shared.footer.privacy'))
        expect(guest_form).to be_present
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
        expect(user.reload.current_sign_in_at).to be_present
        expect(user.last_sign_in_at).to be_present
        expect(user.current_sign_in_ip).to be_present
        expect(user.last_sign_in_ip).to be_present
      end
    end

    it 'unconfirmed user sign in shows unconfirmed failure' do
      user = create(:user, :unconfirmed)

      post user_session_path,
        params: {
          user: {
            email: user.email,
            password: 'password'
          }
        }

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(flash[:alert]).to eq(I18n.t('devise.failure.unconfirmed'))
      end
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
          expect(user.reload).to be_access_locked
          expect(user.unlock_token).to be_present
          expect(ActionMailer::Base.deliveries.size).to eq(1)
          expect(ActionMailer::Base.deliveries.last.subject).to eq(I18n.t('devise.mailer.unlock_instructions.subject'))
          expect(ActionMailer::Base.deliveries.last.body.decoded).to include(I18n.t('auth.mailer.unlock_instructions.action'))
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

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(document.css('main').size).to eq(1)
        expect(response.body).to include(I18n.t('auth.registrations.new.title'))
        expect(response.body).to include(I18n.t('auth.registrations.new.fields.email'))
        expect(response.body).to include(I18n.t('auth.registrations.new.terms.terms'))
        expect(response.body).to include(I18n.t('auth.registrations.new.terms.privacy'))
        expect(response.body).to include(I18n.t('auth.registrations.new.login_link'))
      end
    end

    it 'registration creates unconfirmed user and sends confirmation mail' do
      email = 'new-confirmable-user@example.com'

      expect do
        post user_registration_path,
          params: {
            user: {
              email: email,
              password: 'password',
              password_confirmation: 'password'
            }
          }
      end.to change(User, :count).by(1)

      user = User.find_by!(email: email)

      aggregate_failures do
        expect(response).to redirect_to(root_path)
        expect(flash[:notice]).to eq(I18n.t('devise.registrations.signed_up_but_unconfirmed'))
        expect(user).not_to be_confirmed
        expect(user.confirmation_token).to be_present
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(ActionMailer::Base.deliveries.last.subject).to eq(I18n.t('devise.mailer.confirmation_instructions.subject'))
      end
    end

    it 'confirmation link confirms the registered user' do
      email = 'confirm-link-user@example.com'
      post user_registration_path,
        params: {
          user: {
            email: email,
            password: 'password',
            password_confirmation: 'password'
          }
        }

      token = confirmation_token_from(ActionMailer::Base.deliveries.last)

      get user_confirmation_path(confirmation_token: token)

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(User.find_by!(email: email)).to be_confirmed
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

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(document.css('main').size).to eq(1)
        expect(response.body).to include(I18n.t('auth.passwords.new.title'))
        expect(response.body).to include(I18n.t('auth.passwords.new.fields.email'))
        expect(response.body).to include(I18n.t('auth.passwords.new.buttons.submit'))
        expect(response.body).to include(I18n.t('auth.passwords.new.back_to_login'))
      end
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
