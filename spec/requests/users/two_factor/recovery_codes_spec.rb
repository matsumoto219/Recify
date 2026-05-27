require 'rails_helper'

RSpec.describe 'User recovery codes', type: :request do
  let(:user) { create(:user) }

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
