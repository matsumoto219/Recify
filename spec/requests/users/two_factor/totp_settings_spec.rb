require 'rails_helper'

RSpec.describe 'User TOTP settings', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }

  def start_totp_setup!
    get new_settings_security_totp_path
    expect(response).to have_http_status(:success)
    session[:totp_setup].fetch('secret')
  end

  def totp_code(secret)
    ROTP::TOTP.new(secret, issuer: 'Recify').now
  end

  describe 'GET /settings/security/totp/new' do
    it '非ログインはloginへ戻す' do
      get new_settings_security_totp_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it 'guest userは利用不可にする' do
      sign_in User.guest!

      get new_settings_security_totp_path

      expect(response).to redirect_to(settings_security_path)
    end

    it 'QRと設定キーを表示し、pending secretはDBへ保存しない' do
      sign_in user

      secret = start_totp_setup!

      aggregate_failures do
        expect(response.body).to include('<svg')
        expect(response.body).to include(secret)
        expect(response.body).not_to include('otpauth://')
        expect(response.body).to include(I18n.t('settings.security.auth.clipboard.copy'))
        expect(user.reload.totp_credential).to be_blank
        expect(response.headers['Cache-Control']).to include('no-store')
      end
    end
  end

  describe 'POST /settings/security/totp' do
    before { sign_in user }

    it 'setup成功でconfirmed credentialとrecovery codesを作成し、平文codeをこのレスポンスだけ表示する' do
      secret = start_totp_setup!
      code = totp_code(secret)

      expect do
        post settings_security_totp_path, params: { code: code }
      end.to change(TotpCredential, :count).by(1)
        .and change(RecoveryCode, :count).by(10)

      created_codes = response.body.scan(/[A-Z0-9]{4}(?:-[A-Z0-9]{4}){4}/)
      credential = user.reload.totp_credential

      aggregate_failures do
        expect(response).to have_http_status(:created)
        expect(credential).to be_confirmed
        expect(credential.totp_secret).to eq(secret)
        expect(session[:totp_setup]).to be_blank
        expect(created_codes.size).to eq(10)
        expect(response.body).not_to include(secret)
        expect(response.body).not_to include('otpauth://')
        expect(user.recovery_codes.pluck(:code_digest).join("\n")).not_to include(*created_codes)
        expect(response.headers['Cache-Control']).to include('no-store')
      end

      get settings_security_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        created_codes.each { |recovery_code| expect(response.body).not_to include(recovery_code) }
      end
    end

    it 'setup失敗ではconfirmed credentialを作らずpending secretを維持する' do
      secret = start_totp_setup!

      expect do
        post settings_security_totp_path, params: { code: '000000' }
      end.not_to change(TotpCredential, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.totp_credential).to be_blank
        expect(user.recovery_codes.count).to eq(0)
        expect(session[:totp_setup]['secret']).to eq(secret)
      end
    end

    it '期限切れpending secretは拒否する' do
      start_totp_setup!

      travel 11.minutes do
        post settings_security_totp_path, params: { code: '123456' }
      end

      aggregate_failures do
        expect(response).to redirect_to(new_settings_security_totp_path)
        expect(session[:totp_setup]).to be_blank
      end
    end

    it 'AuditLogを作成しない' do
      secret = start_totp_setup!

      expect do
        post settings_security_totp_path, params: { code: totp_code(secret) }
      end.not_to change(AuditLog, :count)
    end
  end

  describe 'DELETE /settings/security/totp' do
    before { sign_in user }

    it 'TOTP credentialとrecovery codesを削除する' do
      create(:totp_credential, user: user)
      TwoFactor.generate_recovery_codes_for(user: user)

      expect do
        delete settings_security_totp_path
      end.to change(TotpCredential, :count).by(-1)
        .and change(RecoveryCode, :count).by(-10)

      expect(response).to redirect_to(settings_security_path(anchor: 'two-factor'))
    end
  end

  describe 'GET /settings/security' do
    it 'TOTP状態を表示し、secretやrecovery code平文を再表示しない' do
      sign_in user
      secret = 'JBSWY3DPEHPK3PXP'
      create(:totp_credential, user: user, totp_secret: secret, confirmed_at: Time.current)
      recovery_codes = TwoFactor.generate_recovery_codes_for(user: user)

      get settings_security_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('settings.security.auth.two_factor.regenerate_recovery_codes'))
        expect(response.body).not_to include(secret)
        recovery_codes.each { |code| expect(response.body).not_to include(code) }
      end
    end
  end
end
