require 'rails_helper'

RSpec.describe 'User TOTP step-up', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  def create_confirmed_totp(user, secret: nil)
    create(:totp_credential, user: user, totp_secret: secret || ROTP::Base32.random, confirmed_at: Time.current)
  end

  def totp_code(credential)
    ROTP::TOTP.new(credential.totp_secret, issuer: 'Recify').now
  end

  def start_pending_totp(user, remember_me: '0')
    post user_session_path,
         params: {
           user: {
             email: user.email,
             password: 'password',
             remember_me: remember_me
           }
         }

    expect(response).to redirect_to(users_two_factor_totp_path)
  end

  describe 'GET /users/two_factor/totp' do
    it 'pending sessionがない場合はログインへ戻す' do
      get users_two_factor_totp_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it 'pending userだけTOTP画面を表示し、secretを出さない' do
      user = create(:user)
      credential = create_confirmed_totp(user)
      start_pending_totp(user)

      get users_two_factor_totp_path

      document = Nokogiri::HTML(response.body)
      code_input = document.at_css("input[name='code']")
      password_reveal_wrapper = code_input.ancestors.find do |node|
        node['data-controller'].to_s.split.include?('password-reveal')
      end

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('auth.two_factor.totp.title'))
        expect(response.body).to include(I18n.t('auth.two_factor.totp.button'))
        expect(code_input['placeholder']).to eq(I18n.t('auth.two_factor.totp.code_placeholder'))
        expect(password_reveal_wrapper).to be_nil
        expect(response.body).not_to include(credential.totp_secret)
        expect(response.body).not_to include('recovery_code=')
      end
    end

    it 'allowed_methodsにTOTPがない場合は拒否する' do
      user = create(:user)
      TwoFactor.generate_recovery_codes_for(user: user)
      post user_session_path, params: { user: { email: user.email, password: 'password' } }

      get users_two_factor_totp_path

      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'POST /users/two_factor/totp' do
    it 'pending sessionがない場合はログイン不可にする' do
      post users_two_factor_totp_create_path, params: { code: '123456' }

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(session[:pending_second_factor]).to be_blank
      end
    end

    it 'allowed_methodsにTOTPがない場合は拒否する' do
      user = create(:user)
      TwoFactor.generate_recovery_codes_for(user: user)

      post user_session_path,
           params: { user: { email: user.email, password: 'password' } }
      expect(response).to redirect_to(users_two_factor_recovery_code_path)

      post users_two_factor_totp_create_path, params: { code: '123456' }

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(session[:pending_second_factor]).to be_blank
        expect(user.reload.sign_in_count).to eq(0)
      end
    end

    it 'TOTP成功でログインし、pendingを削除してTrackableを更新する' do
      user = create(:user)
      credential = create_confirmed_totp(user)
      start_pending_totp(user)

      expect do
        post users_two_factor_totp_create_path, params: { code: totp_code(credential) }
      end.to change { user.reload.sign_in_count }.from(0).to(1)
        .and change(UserSession, :count).by(1)

      user_session = UserSession.last

      aggregate_failures do
        expect(response).to redirect_to(root_path)
        expect(session[:pending_second_factor]).to be_blank
        expect(session[:user_session_version]).to eq(user.session_version)
        expect(session[:security_reauthentication]).to include(
          'user_id' => user.id,
          'session_version' => user.session_version,
          'method' => 'password_totp_step_up'
        )
        expect(user_session.user).to eq(user)
        expect(user_session.sign_in_method).to eq('password_totp_step_up')
        expect(credential.reload.last_used_at).to be_present
      end
    end

    it 'login_restricted中は既存pendingからのTOTP step-up完了を拒否する' do
      user = create(:user)
      credential = create_confirmed_totp(user)
      start_pending_totp(user)
      create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))

      expect do
        post users_two_factor_totp_create_path, params: { code: totp_code(credential) }
      end.not_to change(UserSession, :count)

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(flash[:warning]).to eq(I18n.t('auth.two_factor.messages.expired'))
        expect(flash[:alert]).to be_blank
        expect(session[:pending_second_factor]).to be_blank
        expect(session[:user_session_version]).to be_blank
        expect(session[:user_session_uid]).to be_blank
        expect(user.reload.sign_in_count).to eq(0)
        expect(credential.reload.last_used_at).to be_blank
      end
    end

    it 'TOTP失敗ではpendingを維持する' do
      user = create(:user)
      credential = create_confirmed_totp(user)
      start_pending_totp(user)

      expect do
        post users_two_factor_totp_create_path, params: { code: '000000' }
      end.not_to change { user.reload.failed_attempts }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(session[:pending_second_factor]).to be_present
        expect(user.reload.sign_in_count).to eq(0)
        expect(credential.reload.last_used_at).to be_blank
      end
    end

    it 'remember_meをstep-up成功後に反映する' do
      user = create(:user)
      credential = create_confirmed_totp(user)
      start_pending_totp(user, remember_me: '1')

      expect do
        post users_two_factor_totp_create_path, params: { code: totp_code(credential) }
      end.to change { user.reload.remember_created_at }.from(nil)
    end

    it 'pending TTL切れは拒否しpendingを削除する' do
      user = create(:user)
      credential = create_confirmed_totp(user)
      start_pending_totp(user)

      travel 6.minutes do
        post users_two_factor_totp_create_path, params: { code: totp_code(credential) }
      end

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(session[:pending_second_factor]).to be_blank
      end
    end

    it '他ユーザーのTOTP codeを拒否する' do
      user = create(:user)
      other_user = create(:user)
      credential = create_confirmed_totp(user)
      other_credential = create_confirmed_totp(other_user)
      start_pending_totp(user)

      post users_two_factor_totp_create_path, params: { code: totp_code(other_credential) }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(session[:pending_second_factor]).to be_present
        expect(user.reload.sign_in_count).to eq(0)
        expect(credential.reload.last_used_at).to be_blank
        expect(other_credential.reload.last_used_at).to be_blank
      end
    end

    it 'pending後にlocked userになった場合はstep-upできない' do
      user = create(:user)
      credential = create_confirmed_totp(user)
      start_pending_totp(user)
      user.lock_access!(send_instructions: false)

      post users_two_factor_totp_create_path, params: { code: totp_code(credential) }

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(session[:pending_second_factor]).to be_blank
        expect(user.reload.sign_in_count).to eq(0)
      end
    end

    it 'pending後にunconfirmed userになった場合はstep-upできない' do
      user = create(:user)
      credential = create_confirmed_totp(user)
      start_pending_totp(user)
      user.update!(confirmed_at: nil)

      post users_two_factor_totp_create_path, params: { code: totp_code(credential) }

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(session[:pending_second_factor]).to be_blank
        expect(user.reload.sign_in_count).to eq(0)
      end
    end
  end
end
