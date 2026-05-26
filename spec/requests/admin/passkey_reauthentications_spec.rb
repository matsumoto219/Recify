require 'rails_helper'
require 'webauthn/fake_client'

RSpec.describe 'Admin passkey reauthentication', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:client) { WebAuthn::FakeClient.new('http://localhost:3000') }

  around do |example|
    original_show_exceptions = Rails.application.env_config['action_dispatch.show_exceptions']
    original_show_detailed_exceptions = Rails.application.env_config['action_dispatch.show_detailed_exceptions']

    Rails.application.env_config['action_dispatch.show_exceptions'] = :all
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = false

    example.run
  ensure
    Rails.application.env_config['action_dispatch.show_exceptions'] = original_show_exceptions
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = original_show_detailed_exceptions
  end

  def create_passkey_with_fake_client(user)
    options = Passkeys.registration_options(user: user)
    credential = client.create(challenge: options.challenge, rp_id: 'localhost', user_verified: true)

    Passkeys.verify_registration(user: user, credential: credential, challenge: options.challenge)
  end

  def reauthentication_options_payload
    post options_admin_passkey_reauthentication_path, as: :json
    expect(response).to have_http_status(:success)

    response.parsed_body.fetch('publicKey')
  end

  def fake_reauthentication_credential(options, passkey:)
    client.get(
      challenge: options.fetch('challenge'),
      rp_id: 'localhost',
      user_verified: true,
      allow_credentials: [ passkey.credential_id ]
    )
  end

  describe 'GET /admin/reauth/passkey/new' do
    it '非ログインユーザーはログインへリダイレクトする' do
      get new_admin_passkey_reauthentication_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it '非adminには既存404を返す' do
      user = create(:user)
      sign_in user

      get new_admin_passkey_reauthentication_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.body).to include(I18n.t('errors.not_found.title'))
        expect(response.body).not_to include('管理者パスキー再認証')
      end
    end

    it 'admin passkey未登録なら登録案内を表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get new_admin_passkey_reauthentication_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('パスキーが登録されていません')
        expect(response.body).to include(settings_security_path(anchor: 'passkeys'))
      end
    end

    it 'admin passkey登録済みなら再認証UIを表示し、credential materialを出さない' do
      admin = create(:user, :admin)
      passkey = create(:passkey, user: admin, credential_id: 'credential-secret', public_key: 'public-key-secret')
      sign_in admin

      get new_admin_passkey_reauthentication_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('パスキーで再認証')
        expect(response.body).to include('data-controller="passkey-session"')
        expect(response.body).to include('data-passkey-session-conditional-value="false"')
        expect(response.body).not_to include(passkey.credential_id)
        expect(response.body).not_to include(passkey.public_key)
        expect(response.body).not_to include('challenge')
      end
    end

    it 'freshness helperは5分windowを判定する' do
      admin = create(:user, :admin)
      passkey = create_passkey_with_fake_client(admin)
      sign_in admin

      options = reauthentication_options_payload
      credential = fake_reauthentication_credential(options, passkey: passkey)
      post admin_passkey_reauthentication_path,
           params: { credential: credential },
           as: :json

      get new_admin_passkey_reauthentication_path
      expect(response.body).to include('fresh passkey reauthentication is active')

      travel 6.minutes do
        get new_admin_passkey_reauthentication_path
        expect(response.body).not_to include('fresh passkey reauthentication is active')
      end
    end
  end

  describe 'POST /admin/reauth/passkey/options' do
    it 'current adminのpasskeysだけをallowCredentialsに含め、challengeを保存する' do
      admin = create(:user, :admin)
      passkey = create_passkey_with_fake_client(admin)
      other_passkey = create_passkey_with_fake_client(create(:user, :admin))
      sign_in admin

      post options_admin_passkey_reauthentication_path, as: :json

      payload = response.parsed_body.fetch('publicKey')
      allow_credential_ids = payload.fetch('allowCredentials').map { |credential| credential.fetch('id') }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(payload.fetch('userVerification')).to eq('required')
        expect(allow_credential_ids).to include(passkey.credential_id)
        expect(allow_credential_ids).not_to include(other_passkey.credential_id)
        expect(session[:admin_passkey_reauthentication_challenge]['challenge']).to eq(payload.fetch('challenge'))
      end
    end

    it 'passkey未登録adminは失敗auditを残す' do
      admin = create(:user, :admin)
      sign_in admin

      expect do
        post options_admin_passkey_reauthentication_path, as: :json
      end.to change(AuditLog, :count).by(1)

      audit_log = AuditLog.last

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(audit_log.action).to eq('admin.passkey_reauthentication.failed')
        expect(audit_log.error_code).to eq('passkey_not_registered')
        expect(audit_log.metadata).to eq('method' => 'passkey')
      end
    end
  end

  describe 'POST /admin/reauth/passkey' do
    it '再認証成功でfreshness sessionを保存し、challengeを削除してAuditLogへ記録する' do
      admin = create(:user, :admin)
      passkey = create_passkey_with_fake_client(admin)
      sign_in admin
      get new_admin_passkey_reauthentication_path(return_to: admin_receipt_analysis_runs_path)
      options = reauthentication_options_payload
      credential = fake_reauthentication_credential(options, passkey: passkey)

      expect do
        post admin_passkey_reauthentication_path,
             params: { credential: credential },
             as: :json,
             headers: { 'HTTP_USER_AGENT' => 'Admin Reauth Spec' }
      end.to change(AuditLog, :count).by(1)

      audit_log = AuditLog.last

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.parsed_body.fetch('ok')).to be(true)
        expect(response.parsed_body.fetch('redirect_url')).to eq(admin_receipt_analysis_runs_path)
        expect(session[:admin_passkey_reauthenticated_at]).to be_present
        expect(session[:admin_passkey_reauthentication_method]).to eq('passkey')
        expect(session[:admin_passkey_reauthentication_challenge]).to be_blank
        expect(passkey.reload.last_used_at).to be_present
        expect(audit_log).to have_attributes(
          actor_user: admin,
          action: 'admin.passkey_reauthentication.succeeded',
          outcome: 'succeeded',
          error_code: nil
        )
        expect(audit_log.metadata).to eq('method' => 'passkey')
        expect(audit_log.request_id).to be_present
        expect(audit_log.ip_address).to be_present
        expect(audit_log.user_agent).to eq('Admin Reauth Spec')
      end
    end

    it '再認証失敗でfreshnessを保存せず、challengeを削除してAuditLogへ記録する' do
      admin = create(:user, :admin)
      create_passkey_with_fake_client(admin)
      sign_in admin
      reauthentication_options_payload

      expect do
        post admin_passkey_reauthentication_path,
             params: { credential: { id: 'invalid-credential' } },
             as: :json
      end.to change(AuditLog, :count).by(1)

      audit_log = AuditLog.last

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch('ok')).to be(false)
        expect(session[:admin_passkey_reauthenticated_at]).to be_blank
        expect(session[:admin_passkey_reauthentication_method]).to be_blank
        expect(session[:admin_passkey_reauthentication_challenge]).to be_blank
        expect(audit_log.action).to eq('admin.passkey_reauthentication.failed')
        expect(audit_log.outcome).to eq('failed')
        expect(audit_log.error_code).to eq('passkey_reauthentication_failed')
        expect(audit_log.metadata).to eq('method' => 'passkey')
      end
    end

    it '期限切れchallengeを拒否する' do
      admin = create(:user, :admin)
      passkey = create_passkey_with_fake_client(admin)
      sign_in admin
      options = reauthentication_options_payload
      credential = fake_reauthentication_credential(options, passkey: passkey)

      travel 6.minutes do
        post admin_passkey_reauthentication_path,
             params: { credential: credential },
             as: :json
      end

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(session[:admin_passkey_reauthenticated_at]).to be_blank
        expect(session[:admin_passkey_reauthentication_challenge]).to be_blank
        expect(AuditLog.last.error_code).to eq('challenge_missing')
      end
    end

    it 'AuditLogにcredential_id/challenge/public_keyを保存しない' do
      admin = create(:user, :admin)
      passkey = create_passkey_with_fake_client(admin)
      sign_in admin
      options = reauthentication_options_payload
      credential = fake_reauthentication_credential(options, passkey: passkey)

      post admin_passkey_reauthentication_path,
           params: { credential: credential },
           as: :json

      audit_payload = AuditLog.last.attributes.to_json

      aggregate_failures do
        expect(audit_payload).not_to include(passkey.credential_id)
        expect(audit_payload).not_to include(passkey.public_key)
        expect(audit_payload).not_to include(options.fetch('challenge'))
      end
    end
  end
end
