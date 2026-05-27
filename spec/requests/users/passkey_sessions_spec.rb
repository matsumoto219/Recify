require 'rails_helper'
require 'webauthn/fake_client'

RSpec.describe 'User passkey sessions', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:client) { WebAuthn::FakeClient.new('http://localhost:3000') }

  def create_passkey_with_fake_client(user)
    options = Passkeys.registration_options(user: user)
    credential = client.create(challenge: options.challenge, rp_id: 'localhost', user_verified: true)

    Passkeys.verify_registration(user: user, credential: credential, challenge: options.challenge)
  end

  def authentication_options_payload
    post users_passkey_sessions_options_path, as: :json
    expect(response).to have_http_status(:success)

    response.parsed_body.fetch('publicKey')
  end

  def fake_assertion_credential(options, user:)
    credential_user_handle = WebAuthn.standard_encoder.decode(user.ensure_webauthn_id!)
    client.get(
      challenge: options.fetch('challenge'),
      rp_id: 'localhost',
      user_verified: true,
      user_handle: credential_user_handle
    )
  end

  describe 'POST /users/passkey_sessions/options' do
    it 'discoverable login optionsを返し、challengeをsessionに保存する' do
      post users_passkey_sessions_options_path, as: :json

      payload = response.parsed_body.fetch('publicKey')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(payload.fetch('challenge')).to be_present
        expect(payload.fetch('rpId')).to eq('localhost')
        expect(payload.fetch('userVerification')).to eq('required')
        expect(payload.fetch('allowCredentials')).to eq([])
        expect(session[:passkey_authentication_challenge]['challenge']).to eq(payload.fetch('challenge'))
      end
    end
  end

  describe 'POST /users/passkey_sessions' do
    it 'challengeなしは汎用エラーで拒否する' do
      post users_passkey_sessions_path,
           params: { credential: { id: 'missing-challenge' } },
           as: :json

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch('error')).to eq(I18n.t('auth.sessions.passkey.messages.failure'))
      end
    end

    it 'discoverable credentialでログインし、challengeを削除してTrackableを更新する' do
      user = create(:user)
      passkey = create_passkey_with_fake_client(user)
      options = authentication_options_payload
      credential = fake_assertion_credential(options, user: user)

      expect do
        post users_passkey_sessions_path,
             params: { credential: credential },
             as: :json
      end.to change { user.reload.sign_in_count }.from(0).to(1)
        .and change(UserSession, :count).by(1)

      user_session = UserSession.last

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.parsed_body.fetch('ok')).to be(true)
        expect(response.parsed_body.fetch('redirect_url')).to be_present
        expect(session[:passkey_authentication_challenge]).to be_blank
        expect(session[:pending_second_factor]).to be_blank
        expect(session[:user_session_version]).to eq(user.session_version)
        expect(session[:user_session_uid]).to be_present
        expect(user_session.user).to eq(user)
        expect(user_session.sign_in_method).to eq('passkey')
        expect(user_session.session_uid_digest).not_to eq(session[:user_session_uid])
        expect(passkey.reload.last_used_at).to be_present
        expect(user.current_sign_in_at).to be_present
        expect(user.current_sign_in_ip).to be_present
      end
    end

    it 'passkey reset後は削除済みcredentialでログインできない' do
      admin = create(:user, :admin)
      user = create(:user)
      passkey = create_passkey_with_fake_client(user)
      options = authentication_options_payload
      credential = fake_assertion_credential(options, user: user)

      result = SystemOperations.execute_user_operation(
        operation: 'force_passkey_reset',
        user: user,
        actor: admin,
        reason: 'passkey recovery request',
        request: nil,
        reauthentication: { method: 'passkey', reauthenticated_at: Time.current },
        confirmation: 'RESET PASSKEYS'
      )

      expect(result).to be_success
      expect(Passkey.find_by(id: passkey.id)).to be_nil

      post users_passkey_sessions_path,
           params: { credential: credential },
           as: :json

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch('error')).to eq(I18n.t('auth.sessions.passkey.messages.failure'))
        expect(user.reload.sign_in_count).to eq(0)
      end
    end

    it 'password step-up pending中でもpasskey直接ログイン成功時はpendingを削除する' do
      user = create(:user)
      create_passkey_with_fake_client(user)

      post user_session_path,
           params: { user: { email: user.email, password: 'password' } }
      expect(session[:pending_second_factor]).to be_present

      options = authentication_options_payload
      credential = fake_assertion_credential(options, user: user)

      post users_passkey_sessions_path,
           params: { credential: credential },
           as: :json

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(session[:pending_second_factor]).to be_blank
        expect(session[:passkey_step_up_challenge]).to be_blank
        expect(user.reload.sign_in_count).to eq(1)
      end
    end

    it '期限切れchallengeを拒否する' do
      user = create(:user)
      create_passkey_with_fake_client(user)
      options = authentication_options_payload
      credential = fake_assertion_credential(options, user: user)

      travel 6.minutes do
        post users_passkey_sessions_path,
             params: { credential: credential },
             as: :json
      end

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch('error')).to eq(I18n.t('auth.sessions.passkey.messages.failure'))
        expect(session[:passkey_authentication_challenge]).to be_blank
      end
    end

    it 'user_handle mismatchを汎用エラーで拒否する' do
      user = create(:user)
      other_user = create(:user)
      passkey = create_passkey_with_fake_client(user)
      options = authentication_options_payload
      credential = fake_assertion_credential(options, user: other_user)

      post users_passkey_sessions_path,
           params: { credential: credential },
           as: :json

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch('error')).to eq(I18n.t('auth.sessions.passkey.messages.failure'))
        expect(passkey.reload.last_used_at).to be_blank
      end
    end

    it 'unconfirmed userは拒否する' do
      user = create(:user, :unconfirmed)
      passkey = create_passkey_with_fake_client(user)
      options = authentication_options_payload
      credential = fake_assertion_credential(options, user: user)

      post users_passkey_sessions_path,
           params: { credential: credential },
           as: :json

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch('error')).to eq(I18n.t('auth.sessions.passkey.messages.failure'))
        expect(passkey.reload.last_used_at).to be_blank
        expect(user.reload.sign_in_count).to eq(0)
      end
    end

    it 'locked userは拒否する' do
      user = create(:user)
      passkey = create_passkey_with_fake_client(user)
      user.lock_access!(send_instructions: false)
      options = authentication_options_payload
      credential = fake_assertion_credential(options, user: user)

      post users_passkey_sessions_path,
           params: { credential: credential },
           as: :json

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch('error')).to eq(I18n.t('auth.sessions.passkey.messages.failure'))
        expect(passkey.reload.last_used_at).to be_blank
        expect(user.reload.sign_in_count).to eq(0)
      end
    end

    it 'guest userは拒否する' do
      user = User.guest!
      passkey = create_passkey_with_fake_client(user)
      options = authentication_options_payload
      credential = fake_assertion_credential(options, user: user)

      post users_passkey_sessions_path,
           params: { credential: credential },
           as: :json

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch('error')).to eq(I18n.t('auth.sessions.passkey.messages.failure'))
        expect(passkey.reload.last_used_at).to be_blank
        expect(user.reload.sign_in_count).to eq(0)
      end
    end
  end

  describe 'GET /users/sign_in' do
    it 'password loginを維持し、passkeyログイン導線にcredential materialを出さない' do
      user = create(:user)
      passkey = create(:passkey, user: user, credential_id: 'credential-secret', public_key: 'public-key-secret')

      get new_user_session_path

      document = Nokogiri::HTML(response.body)
      email_input = document.at_css('input[name="user[email]"]')
      passkey_controller = document.at_css('[data-controller~="passkey-session"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('auth.sessions.submit'))
        expect(response.body).to include(I18n.t('auth.sessions.passkey.button'))
        expect(email_input['autocomplete']).to eq('username webauthn')
        expect(passkey_controller).to be_present
        expect(response.body).not_to include(passkey.credential_id)
        expect(response.body).not_to include(passkey.public_key)
        expect(response.body).not_to include('challenge')
      end
    end
  end

  describe 'passkey session JavaScript' do
    it 'conditional UIとAbortControllerを使う' do
      source = Rails.root.join('app/javascript/controllers/passkey_session_controller.js').read

      aggregate_failures do
        expect(source).to include('isConditionalMediationAvailable')
        expect(source).to include("mediation: 'conditional'")
        expect(source).to include('AbortController')
        expect(source).to include('disconnect ()')
      end
    end

    it 'ブラウザ例外messageを画面へ直接表示しない' do
      session_source = Rails.root.join('app/javascript/controllers/passkey_session_controller.js').read
      registration_source = Rails.root.join('app/javascript/controllers/passkey_controller.js').read

      [ session_source, registration_source ].each do |source|
        aggregate_failures do
          expect(source).to include('userFacingErrorMessage')
          expect(source).to include('NotAllowedError')
          expect(source).to include('AbortError')
          expect(source).to include('SecurityError')
          expect(source).to include('InvalidStateError')
          expect(source).not_to include('error.message')
          expect(source).not_to include('The request is not allowed by the user agent')
          expect(source).to include('this.showError(this.userFacingErrorMessage(error))')
        end
      end
    end
  end
end
