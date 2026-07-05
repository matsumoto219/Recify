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

    it 'すでに有効な場合は通常通知で設定へ戻す' do
      sign_in user
      create(:totp_credential, user: user, confirmed_at: Time.current)

      get new_settings_security_totp_path

      aggregate_failures do
        expect(response).to redirect_to(settings_security_path(anchor: "two-factor"))
        expect(flash[:notice]).to eq(I18n.t('settings.security.auth.two_factor.messages.already_enabled'))
      end
    end

    it '手入力用の設定キーはsetup画面限定で表示し、no-storeかつDB/AuditLogへ保存しない' do
      sign_in user

      expect do
        get new_settings_security_totp_path
      end.not_to change(AuditLog, :count)
      expect(response).to have_http_status(:success)
      secret = session[:totp_setup].fetch('secret')
      document = Nokogiri::HTML(response.body)
      settings_section = document.at_css('section.max-w-3xl')
      qr_svg = document.at_css('[data-testid="totp-setup-qr"] svg')
      qr_path = qr_svg&.at_css('path')
      copy_button = document.at_css('[data-action="click->clipboard#copy"]')
      code_input = document.at_css("input[name='code']")
      password_reveal_wrapper = code_input.ancestors.find do |node|
        node['data-controller'].to_s.split.include?('password-reveal')
      end

      aggregate_failures do
        expect(response.body).to include('<svg')
        expect(settings_section['class'].split).to include('w-full', 'min-w-0', 'max-w-3xl')
        expect(qr_svg).to be_present
        expect(response.body).to include('viewBox=')
        expect(qr_svg['width']).to eq('100%')
        expect(qr_svg['height']).to eq('100%')
        expect(qr_path&.[]('d')).to be_present
        expect(qr_path&.[]('transform')).to include('scale(')
        expect(response.body).to include(secret)
        expect(response.body).not_to include('otpauth://')
        expect(code_input['placeholder']).to eq(I18n.t('settings.security.auth.two_factor.setup.code_placeholder'))
        expect(password_reveal_wrapper).to be_nil
        expect(response.body).to include(I18n.t('settings.security.auth.clipboard.copy'))
        expect(copy_button['class']).to include('whitespace-nowrap')
        expect(copy_button['class']).to include('shrink-0')
        expect(user.reload.totp_credential).to be_blank
        expect(response.headers['Cache-Control']).to include('no-store')
      end

      get settings_security_path

      expect(response.body).not_to include(secret)
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
      document = Nokogiri::HTML(response.body)
      settings_section = document.at_css('section.max-w-3xl')

      aggregate_failures do
        expect(response).to have_http_status(:created)
        expect(settings_section['class'].split).to include('w-full', 'min-w-0', 'max-w-3xl')
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

    it 'すでに有効な場合は通常通知で設定へ戻す' do
      create(:totp_credential, user: user, confirmed_at: Time.current)

      post settings_security_totp_path, params: { code: '123456' }

      aggregate_failures do
        expect(response).to redirect_to(settings_security_path(anchor: "two-factor"))
        expect(flash[:notice]).to eq(I18n.t('settings.security.auth.two_factor.messages.already_enabled'))
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
