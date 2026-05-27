require 'rails_helper'

RSpec.describe 'User recovery codes', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }

  def start_pending_recovery_code(user, remember_me: '0')
    post user_session_path,
         params: {
           user: {
             email: user.email,
             password: 'password',
             remember_me: remember_me
           }
         }

    expect(response).to redirect_to(users_two_factor_recovery_code_path)
  end

  describe 'GET /users/two_factor/recovery_code' do
    it 'pending sessionがない場合はログインへ戻す' do
      get users_two_factor_recovery_code_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it 'pending userだけrecovery code画面を表示し、code平文を出さない' do
      codes = TwoFactor.generate_recovery_codes_for(user: user)
      start_pending_recovery_code(user)

      get users_two_factor_recovery_code_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('auth.two_factor.recovery_code.title'))
        expect(response.body).to include(I18n.t('auth.two_factor.recovery_code.button'))
        codes.each { |code| expect(response.body).not_to include(code) }
      end
    end
  end

  describe 'POST /users/two_factor/recovery_code' do
    it 'pending sessionがない場合はログイン不可にする' do
      post users_two_factor_recovery_code_create_path, params: { code: 'ABCD-EFGH-IJKL-MNOP-QRST' }

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(session[:pending_second_factor]).to be_blank
      end
    end

    it 'allowed_methodsにrecovery codeがない場合は拒否する' do
      create(:totp_credential, user: user, confirmed_at: Time.current)

      post user_session_path,
           params: { user: { email: user.email, password: 'password' } }
      expect(response).to redirect_to(users_two_factor_totp_path)

      post users_two_factor_recovery_code_create_path, params: { code: 'ABCD-EFGH-IJKL-MNOP-QRST' }

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(session[:pending_second_factor]).to be_blank
        expect(user.reload.sign_in_count).to eq(0)
      end
    end

    it 'recovery code成功でログインし、使用済みにして再利用不可にする' do
      code = TwoFactor.generate_recovery_codes_for(user: user).first
      start_pending_recovery_code(user)

      expect do
        post users_two_factor_recovery_code_create_path, params: { code: code }
      end.to change { user.reload.sign_in_count }.from(0).to(1)
        .and change(UserSession, :count).by(1)

      used_code = user.recovery_codes.find_by(code_digest: TwoFactor.recovery_code_digest(code))
      user_session = UserSession.last

      aggregate_failures do
        expect(response).to redirect_to(root_path)
        expect(session[:pending_second_factor]).to be_blank
        expect(session[:user_session_version]).to eq(user.session_version)
        expect(session[:user_session_uid]).to be_present
        expect(used_code).to be_used
        expect(user_session.sign_in_method).to eq('password_recovery_code_step_up')
      end

      sign_out user
      post user_session_path, params: { user: { email: user.email, password: 'password' } }
      post users_two_factor_recovery_code_create_path, params: { code: code }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(session[:pending_second_factor]).to be_present
      end
    end

    it 'recovery code失敗ではpendingを維持する' do
      TwoFactor.generate_recovery_codes_for(user: user)
      start_pending_recovery_code(user)

      expect do
        post users_two_factor_recovery_code_create_path, params: { code: 'WRONG-CODE' }
      end.not_to change { user.reload.failed_attempts }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(session[:pending_second_factor]).to be_present
        expect(user.reload.sign_in_count).to eq(0)
      end
    end

    it 'pending TTL切れは拒否しpendingを削除する' do
      code = TwoFactor.generate_recovery_codes_for(user: user).first
      start_pending_recovery_code(user)

      travel 6.minutes do
        post users_two_factor_recovery_code_create_path, params: { code: code }
      end

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(session[:pending_second_factor]).to be_blank
      end
    end

    it 'remember_meをstep-up成功後に反映する' do
      code = TwoFactor.generate_recovery_codes_for(user: user).first
      start_pending_recovery_code(user, remember_me: '1')

      expect do
        post users_two_factor_recovery_code_create_path, params: { code: code }
      end.to change { user.reload.remember_created_at }.from(nil)
    end

    it '他ユーザーのrecovery codeを拒否する' do
      other_user = create(:user)
      TwoFactor.generate_recovery_codes_for(user: user)
      other_code = TwoFactor.generate_recovery_codes_for(user: other_user).first
      other_recovery_code = other_user.recovery_codes.find_by(code_digest: TwoFactor.recovery_code_digest(other_code))
      start_pending_recovery_code(user)

      post users_two_factor_recovery_code_create_path, params: { code: other_code }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(session[:pending_second_factor]).to be_present
        expect(user.reload.sign_in_count).to eq(0)
        expect(other_recovery_code.reload.used_at).to be_blank
      end
    end
  end

  describe 'POST /settings/security/recovery_codes/regenerate' do
    it '非ログインはloginへ戻す' do
      post settings_security_recovery_codes_regenerate_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it 'TOTP未設定の場合は拒否する' do
      sign_in user

      post settings_security_recovery_codes_regenerate_path

      expect(response).to redirect_to(settings_security_path(anchor: 'two-factor'))
    end

    it '既存codeを削除して新しいcodeを発行し、平文はこのレスポンスだけ表示する' do
      sign_in user
      create(:totp_credential, user: user, confirmed_at: Time.current)
      old_codes = TwoFactor.generate_recovery_codes_for(user: user)
      old_digests = user.recovery_codes.pluck(:code_digest)

      expect do
        post settings_security_recovery_codes_regenerate_path
      end.not_to change(RecoveryCode, :count)

      new_codes = response.body.scan(/[A-Z0-9]{4}(?:-[A-Z0-9]{4}){4}/)

      aggregate_failures do
        expect(response).to have_http_status(:created)
        expect(new_codes.size).to eq(10)
        expect(user.recovery_codes.reload.pluck(:code_digest)).not_to include(*old_digests)
        expect(user.recovery_codes.pluck(:code_digest).join("\n")).not_to include(*new_codes)
        old_codes.each { |code| expect(response.body).not_to include(code) }
        expect(response.headers['Cache-Control']).to include('no-store')
      end

      get settings_security_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        new_codes.each { |code| expect(response.body).not_to include(code) }
      end
    end

    it 'AuditLogを作成しない' do
      sign_in user
      create(:totp_credential, user: user, confirmed_at: Time.current)

      expect do
        post settings_security_recovery_codes_regenerate_path
      end.not_to change(AuditLog, :count)
    end
  end
end
