require 'rails_helper'
require 'webauthn/fake_client'

RSpec.describe 'User passkey step-up', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:client) { WebAuthn::FakeClient.new('http://localhost:3000') }

  def create_passkey_with_fake_client(user)
    options = Passkeys.registration_options(user: user)
    credential = client.create(challenge: options.challenge, rp_id: 'localhost', user_verified: true)

    Passkeys.verify_registration(user: user, credential: credential, challenge: options.challenge)
  end

  def start_pending_step_up(user, remember_me: '0')
    post user_session_path,
         params: {
           user: {
             email: user.email,
             password: 'password',
             remember_me: remember_me
           }
         }

    expect(response).to redirect_to(users_two_factor_passkey_path)
  end

  def step_up_options_payload
    post users_two_factor_passkey_options_path, as: :json
    expect(response).to have_http_status(:success)

    response.parsed_body.fetch('publicKey')
  end

  def fake_step_up_credential(options, passkey:)
    client.get(
      challenge: options.fetch('challenge'),
      rp_id: 'localhost',
      user_verified: true,
      allow_credentials: [ passkey.credential_id ]
    )
  end

  describe 'GET /users/two_factor/passkey' do
    it 'pending sessionがない場合はログインへ戻す' do
      get users_two_factor_passkey_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it 'pending userだけstep-up画面を表示し、credential materialを出さない' do
      user = create(:user)
      passkey = create_passkey_with_fake_client(user)
      start_pending_step_up(user)

      get users_two_factor_passkey_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('auth.two_factor.passkey.title'))
        expect(response.body).to include(I18n.t('auth.two_factor.passkey.button'))
        expect(response.body).to include('data-controller="passkey-session"')
        expect(response.body).to include('data-passkey-session-conditional-value="false"')
        expect(response.body).not_to include(passkey.credential_id)
        expect(response.body).not_to include(passkey.public_key)
        expect(response.body).not_to include('challenge')
      end
    end

    it 'pending session期限切れはログインへ戻す' do
      user = create(:user)
      create_passkey_with_fake_client(user)
      start_pending_step_up(user)

      travel 6.minutes do
        get users_two_factor_passkey_path
      end

      aggregate_failures do
        expect(response).to redirect_to(new_user_session_path)
        expect(session[:pending_second_factor]).to be_blank
      end
    end
  end

  describe 'POST /users/two_factor/passkey/options' do
    it 'pending userのpasskeysだけをallowCredentialsに含め、challengeを保存する' do
      user = create(:user)
      passkey = create_passkey_with_fake_client(user)
      other_passkey = create_passkey_with_fake_client(create(:user))
      start_pending_step_up(user)

      post users_two_factor_passkey_options_path, as: :json

      payload = response.parsed_body.fetch('publicKey')
      allow_credential_ids = payload.fetch('allowCredentials').map { |credential| credential.fetch('id') }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(payload.fetch('userVerification')).to eq('required')
        expect(allow_credential_ids).to include(passkey.credential_id)
        expect(allow_credential_ids).not_to include(other_passkey.credential_id)
        expect(session[:passkey_step_up_challenge]['challenge']).to eq(payload.fetch('challenge'))
      end
    end
  end

  describe 'POST /users/two_factor/passkey' do
    it 'step-up成功でログインし、pending/challengeを削除してTrackableを更新する' do
      user = create(:user)
      passkey = create_passkey_with_fake_client(user)
      start_pending_step_up(user)
      options = step_up_options_payload
      credential = fake_step_up_credential(options, passkey: passkey)

      expect do
        post users_two_factor_passkey_create_path,
             params: { credential: credential },
             as: :json
      end.to change { user.reload.sign_in_count }.from(0).to(1)
        .and change(UserSession, :count).by(1)

      user_session = UserSession.last

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.parsed_body.fetch('ok')).to be(true)
        expect(response.parsed_body.fetch('redirect_url')).to be_present
        expect(session[:pending_second_factor]).to be_blank
        expect(session[:passkey_step_up_challenge]).to be_blank
        expect(session[:user_session_version]).to eq(user.session_version)
        expect(session[:user_session_uid]).to be_present
        expect(user_session.user).to eq(user)
        expect(user_session.sign_in_method).to eq('password_passkey_step_up')
        expect(user_session.session_uid_digest).not_to eq(session[:user_session_uid])
        expect(passkey.reload.last_used_at).to be_present
        expect(user.current_sign_in_at).to be_present
        expect(user.current_sign_in_ip).to be_present
      end

      get settings_path

      expect(response).to have_http_status(:success)
    end

    it 'remember_meをstep-up成功後に反映する' do
      user = create(:user)
      passkey = create_passkey_with_fake_client(user)
      start_pending_step_up(user, remember_me: '1')
      options = step_up_options_payload
      credential = fake_step_up_credential(options, passkey: passkey)

      expect do
        post users_two_factor_passkey_create_path,
             params: { credential: credential },
             as: :json
      end.to change { user.reload.remember_created_at }.from(nil)
    end

    it 'step-up失敗でpending sessionを維持しchallengeだけ削除する' do
      user = create(:user)
      create_passkey_with_fake_client(user)
      start_pending_step_up(user)
      step_up_options_payload

      post users_two_factor_passkey_create_path,
           params: { credential: { id: 'invalid-credential' } },
           as: :json

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch('error')).to eq(I18n.t('auth.two_factor.passkey.messages.failure'))
        expect(response.parsed_body.fetch('redirect_url')).to eq(users_two_factor_passkey_path)
        expect(session[:pending_second_factor]).to be_present
        expect(session[:passkey_step_up_challenge]).to be_blank
        expect(user.reload.sign_in_count).to eq(0)
      end
    end

    it '期限切れchallengeを拒否し、pending sessionを維持する' do
      stub_const('Users::SessionsController::PENDING_SECOND_FACTOR_TTL', 10.minutes)
      user = create(:user)
      passkey = create_passkey_with_fake_client(user)
      start_pending_step_up(user)
      options = step_up_options_payload
      credential = fake_step_up_credential(options, passkey: passkey)

      travel 6.minutes do
        post users_two_factor_passkey_create_path,
             params: { credential: credential },
             as: :json
      end

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch('error')).to eq(I18n.t('auth.two_factor.passkey.messages.failure'))
        expect(session[:pending_second_factor]).to be_present
        expect(session[:passkey_step_up_challenge]).to be_blank
      end
    end

    it 'TOTPとrecovery code fallback linkを表示する' do
      user = create(:user)
      create_passkey_with_fake_client(user)
      create(:totp_credential, user: user, confirmed_at: Time.current)
      TwoFactor.generate_recovery_codes_for(user: user)
      start_pending_step_up(user)

      get users_two_factor_passkey_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(users_two_factor_totp_path)
        expect(response.body).to include(users_two_factor_recovery_code_path)
      end
    end
  end
end
