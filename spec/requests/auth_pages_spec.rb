require 'rails_helper'

RSpec.describe 'Auth pages', type: :request do
  describe 'GET /users/sign_in' do
    it 'renders login copy through locale keys and keeps guest login action' do
      get new_user_session_path

      document = Nokogiri::HTML(response.body)
      guest_form = document.at_css("form[action='#{guest_sign_in_path}']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('auth.sessions.title'))
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
  end

  describe 'GET /users/sign_up' do
    it 'renders registration copy through locale keys' do
      get new_user_registration_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('auth.registrations.new.title'))
        expect(response.body).to include(I18n.t('auth.registrations.new.fields.email'))
        expect(response.body).to include(I18n.t('auth.registrations.new.terms.terms'))
        expect(response.body).to include(I18n.t('auth.registrations.new.terms.privacy'))
        expect(response.body).to include(I18n.t('auth.registrations.new.login_link'))
      end
    end
  end

  describe 'GET /users/edit' do
    let(:user) { create(:user) }

    before do
      sign_in user
    end

    it 'renders account edit copy through locale keys' do
      get edit_user_registration_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('auth.registrations.edit.title'))
        expect(response.body).to include(I18n.t('auth.registrations.edit.fields.email'))
        expect(response.body).to include(I18n.t('auth.registrations.edit.fields.current_password'))
        expect(response.body).to include(I18n.t('auth.registrations.edit.buttons.save'))
      end
    end
  end

  describe 'GET /users/password/new' do
    it 'renders password reset copy through locale keys' do
      get new_user_password_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('auth.passwords.new.title'))
        expect(response.body).to include(I18n.t('auth.passwords.new.fields.email'))
        expect(response.body).to include(I18n.t('auth.passwords.new.buttons.submit'))
        expect(response.body).to include(I18n.t('auth.passwords.new.back_to_login'))
      end
    end
  end
end
