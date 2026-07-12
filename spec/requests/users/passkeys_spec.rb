require 'rails_helper'
require 'webauthn/fake_client'

RSpec.describe 'User passkeys', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:client) { WebAuthn::FakeClient.new('http://localhost:3000') }

  def registration_options_payload
    post settings_passkeys_options_path, as: :json
    expect(response).to have_http_status(:success)

    response.parsed_body.fetch('publicKey')
  end

  def fake_registration_credential(options)
    client.create(
      challenge: options.fetch('challenge'),
      rp_id: 'localhost',
      user_verified: true,
      backup_eligibility: true,
      backup_state: true
    )
  end

  describe 'POST /settings/passkeys/options' do
    it '非ログインは拒否する' do
      post settings_passkeys_options_path, as: :json

      expect([ 302, 401 ]).to include(response.status)
    end

    it 'guest userは登録不可にする' do
      guest = User.guest!
      sign_in guest

      post settings_passkeys_options_path, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch('error')).to eq(I18n.t('settings.security.auth.passkey.messages.unavailable'))
    end

    it 'confirmed userはoptionsを取得でき、challengeをsessionに保存する' do
      sign_in user
      mark_security_reauthentication_fresh!(user)

      post settings_passkeys_options_path, as: :json

      payload = response.parsed_body.fetch('publicKey')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(payload.fetch('challenge')).to be_present
        expect(payload.dig('rp', 'id')).to eq('localhost')
        expect(payload.dig('rp', 'name')).to eq('Recify')
        expect(payload.dig('authenticatorSelection', 'userVerification')).to eq('required')
        expect(payload.dig('authenticatorSelection', 'residentKey')).to eq('required')
        expect(payload.dig('authenticatorSelection', 'requireResidentKey')).to be(true)
        expect(session[:passkey_registration_challenge]['challenge']).to eq(payload.fetch('challenge'))
        expect(user.reload.webauthn_id).to be_present
      end
    end

    it '古いlogin sessionではchallengeを発行せず再認証を要求する' do
      sign_in user

      post settings_passkeys_options_path, as: :json

      aggregate_failures do
        expect(response).to have_http_status(:precondition_required)
        expect(response.parsed_body.fetch('reauthentication_url')).to include('/settings/security/reauthentication/new')
        expect(session[:passkey_registration_challenge]).to be_blank
      end
    end

    it '9個登録済みでもoptionsを取得できる' do
      create_list(:passkey, Passkey::MAX_PER_USER - 1, user: user)
      sign_in user
      mark_security_reauthentication_fresh!(user)

      post settings_passkeys_options_path, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body.fetch('publicKey').fetch('challenge')).to be_present
    end

    it '10個登録済みの場合はoptions発行を拒否する' do
      create_list(:passkey, Passkey::MAX_PER_USER, user: user)
      sign_in user
      mark_security_reauthentication_fresh!(user)

      post settings_passkeys_options_path, as: :json

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch('ok')).to be(false)
        expect(response.parsed_body.fetch('error')).to eq(I18n.t('settings.security.auth.passkey.messages.limit_reached', count: Passkey::MAX_PER_USER))
        expect(session[:passkey_registration_challenge]).to be_blank
      end
    end

    it 'adminも10個登録済みの場合はoptions発行を拒否する' do
      admin = create(:user, :admin)
      create_list(:passkey, Passkey::MAX_PER_USER, user: admin)
      sign_in admin
      mark_security_reauthentication_fresh!(admin)

      post settings_passkeys_options_path, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch('error')).to eq(I18n.t('settings.security.auth.passkey.messages.limit_reached', count: Passkey::MAX_PER_USER))
    end
  end

  describe 'POST /settings/passkeys' do
    before do
      sign_in user
      mark_security_reauthentication_fresh!(user)
    end

    it 'challengeなしcreateは拒否する' do
      post settings_passkeys_path,
           params: { label: 'MacBook', credential: { id: 'missing-challenge' } },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch('error')).to eq(I18n.t('settings.security.auth.passkey.messages.challenge_missing'))
    end

    it 'create成功でpasskeyを作成し、session challengeを削除する' do
      options = registration_options_payload
      credential = fake_registration_credential(options)

      expect do
        post settings_passkeys_path,
             params: { label: 'MacBook Touch ID', credential: credential },
             as: :json
      end.to change(user.passkeys, :count).by(1)

      passkey = user.passkeys.last

      aggregate_failures do
        expect(response).to have_http_status(:created)
        expect(response.parsed_body.fetch('ok')).to be(true)
        expect(passkey.label).to eq('MacBook Touch ID')
        expect(passkey.credential_id).to be_present
        expect(passkey.public_key).to be_present
        expect(passkey.transports).to eq([ 'internal' ])
        expect(passkey.backup_eligible).to be(true)
        expect(passkey.backed_up).to be(true)
        expect(session[:passkey_registration_challenge]).to be_blank
      end
    end

    it '10個登録済みの場合はcreate直叩きを拒否する' do
      create_list(:passkey, Passkey::MAX_PER_USER - 1, user: user)
      options = registration_options_payload
      credential = fake_registration_credential(options)
      create(:passkey, user: user)

      expect do
        post settings_passkeys_path,
             params: { label: 'Over limit', credential: credential },
             as: :json
      end.not_to change(user.passkeys, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch('ok')).to be(false)
        expect(response.parsed_body.fetch('error')).to eq(I18n.t('settings.security.auth.passkey.messages.limit_reached', count: Passkey::MAX_PER_USER))
        expect(session[:passkey_registration_challenge]).to be_blank
      end
    end

    it 'duplicate credentialは拒否する' do
      options = registration_options_payload
      credential = fake_registration_credential(options)
      credential_id = WebAuthn::Credential.from_create(credential).id
      create(:passkey, credential_id: credential_id)

      expect do
        post settings_passkeys_path,
             params: { label: 'Duplicate', credential: credential },
             as: :json
      end.not_to change(Passkey, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'challenge mismatchを拒否する' do
      options = registration_options_payload
      credential = fake_registration_credential(options.merge('challenge' => WebAuthn.generate_user_id))

      post settings_passkeys_path,
           params: { label: 'Mismatch', credential: credential },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it '期限切れchallengeを拒否する' do
      options = registration_options_payload
      credential = fake_registration_credential(options)

      travel 6.minutes do
        mark_security_reauthentication_fresh!(user)
        post settings_passkeys_path,
             params: { label: 'Expired', credential: credential },
             as: :json
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.fetch('error')).to eq(I18n.t('settings.security.auth.passkey.messages.challenge_missing'))
    end

    it '本人確認期限切れではcredentialを検証せずchallengeも破棄する' do
      options = registration_options_payload
      credential = fake_registration_credential(options)

      travel 6.minutes do
        expect do
          post settings_passkeys_path,
               params: { label: 'Stale reauthentication', credential: credential },
               as: :json
        end.not_to change(user.passkeys, :count)
      end

      aggregate_failures do
        expect(response).to have_http_status(:precondition_required)
        expect(session[:passkey_registration_challenge]).to be_blank
      end
    end

    it 'challenge発行後に再認証し直した場合は古いchallengeを拒否する' do
      options = registration_options_payload
      credential = fake_registration_credential(options)

      travel 1.second do
        mark_security_reauthentication_fresh!(user)
        post settings_passkeys_path,
             params: { label: 'Old capability', credential: credential },
             as: :json
      end

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch('error')).to eq(I18n.t('settings.security.auth.passkey.messages.challenge_missing'))
        expect(user.passkeys).to be_empty
      end
    end

    it 'AuditLogへraw credential materialを出さない' do
      options = registration_options_payload
      credential = fake_registration_credential(options)

      expect do
        post settings_passkeys_path,
             params: { label: 'No Audit', credential: credential },
             as: :json
      end.not_to change(AuditLog, :count)
    end
  end

  describe 'DELETE /settings/passkeys/:uid' do
    before do |example|
      sign_in user
      mark_security_reauthentication_fresh!(user) unless example.metadata[:stale_reauthentication]
    end

    it '自分のpasskeyを削除できる' do
      passkey = create(:passkey, user: user)

      expect do
        delete settings_passkey_path(passkey)
      end.to change(user.passkeys, :count).by(-1)

      aggregate_failures do
        expect(settings_passkey_path(passkey)).to eq("/settings/passkeys/#{passkey.uid}")
        expect(response).to redirect_to(settings_security_path(anchor: 'passkeys'))
      end
    end

    it '古いlogin sessionでは自分のpasskeyも削除しない', :stale_reauthentication do
      passkey = create(:passkey, user: user)

      expect do
        delete settings_passkey_path(passkey)
      end.not_to change(user.passkeys, :count)

      expect(response.location).to include('/settings/security/reauthentication/new')
    end

    it '10個登録済みでも削除できる' do
      passkeys = create_list(:passkey, Passkey::MAX_PER_USER, user: user)

      expect do
        delete settings_passkey_path(passkeys.first)
      end.to change(user.passkeys, :count).by(-1)

      expect(response).to redirect_to(settings_security_path(anchor: 'passkeys'))
    end

    it '削除後はoptions取得と再登録ができる' do
      passkeys = create_list(:passkey, Passkey::MAX_PER_USER, user: user)
      delete settings_passkey_path(passkeys.first)

      options = registration_options_payload
      credential = fake_registration_credential(options)

      expect do
        post settings_passkeys_path,
             params: { label: 'Recreated', credential: credential },
             as: :json
      end.to change(user.passkeys, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it '内部IDのURLでは削除できない' do
      passkey = create(:passkey, user: user)

      expect do
        delete "/settings/passkeys/#{passkey.id}"
      end.not_to change(user.passkeys, :count)

      expect(response).to have_http_status(:not_found)
    end

    it '他人のpasskeyは削除できない' do
      passkey = create(:passkey)

      expect do
        delete settings_passkey_path(passkey)
      end.not_to change(Passkey, :count)

      expect(response).to have_http_status(:not_found)
    end

    it 'guest userは削除不可にする' do
      sign_out user
      guest = User.guest!
      sign_in guest
      passkey = create(:passkey)

      delete settings_passkey_path(passkey)

      expect(response).to redirect_to(settings_security_path)
    end
  end

  describe 'GET /settings/security' do
    it '登録済みpasskeyを表示し、credential materialを表示しない' do
      sign_in user
      passkey = create(
        :passkey,
        user: user,
        label: 'MacBook Touch ID',
        credential_id: 'credential-secret',
        public_key: 'public-key-secret',
        backup_eligible: true,
        backed_up: true
      )

      get settings_security_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('MacBook Touch ID')
        expect(response.body).to include(I18n.t('settings.security.auth.passkey.action'))
        expect(response.body).to include(settings_passkey_path(passkey))
        expect(response.body).not_to include("/settings/passkeys/#{passkey.id}")
        expect(response.body).not_to include(passkey.credential_id)
        expect(response.body).not_to include(passkey.public_key)
        expect(response.body).not_to include('backup_eligible')
        expect(response.body).not_to include('backed_up')
        expect(response.body).not_to include('バックアップ')
      end
    end

    it 'guest userにはpasskey登録不可メッセージを表示する' do
      sign_out user
      guest = User.guest!
      sign_in guest

      get settings_security_path

      expect(response.body).to include(I18n.t('settings.security.auth.passkey.guest_unavailable'))
    end
  end
end
