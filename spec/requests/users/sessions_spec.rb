require 'rails_helper'
require 'webauthn/fake_client'

RSpec.describe 'User password sessions', type: :request do
  let(:client) { WebAuthn::FakeClient.new('http://localhost:3000') }

  def create_passkey_with_fake_client(user)
    options = Passkeys.registration_options(user: user)
    credential = client.create(challenge: options.challenge, rp_id: 'localhost', user_verified: true)

    Passkeys.verify_registration(user: user, credential: credential, challenge: options.challenge)
  end

  it 'passkey未登録userはpassword loginで従来通りログイン完了する' do
    user = create(:user)

    expect do
      post user_session_path,
           params: { user: { email: user.email, password: 'password' } }
    end.to change { user.reload.sign_in_count }.from(0).to(1)

    aggregate_failures do
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(root_path)
      expect(session[:pending_second_factor]).to be_blank
      expect(user.current_sign_in_at).to be_present
      expect(user.current_sign_in_ip).to be_present
    end
  end

  it 'passkey登録済みuserはpassword login後にpending状態でstep-upへ進み、まだログイン完了しない' do
    user = create(:user)
    create_passkey_with_fake_client(user)

    expect do
      post user_session_path,
           params: { user: { email: user.email, password: 'password' } }
    end.not_to change { user.reload.sign_in_count }

    pending = session[:pending_second_factor]

    aggregate_failures do
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(users_two_factor_passkey_path)
      expect(pending['user_id']).to eq(user.id)
      expect(pending['method']).to eq('password')
      expect(pending['allowed_methods']).to eq([ 'passkey' ])
      expect(pending['remember_me']).to be(false)
      expect(pending['issued_at']).to be_present
      expect(user.current_sign_in_at).to be_blank
    end

    get settings_path

    expect(response).to redirect_to(new_user_session_path)
  end

  it 'passkey reset後はpassword loginでstep-up不要のログインに戻る' do
    admin = create(:user, :admin)
    user = create(:user)
    create_passkey_with_fake_client(user)

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
    expect(user.passkeys.reload).to be_empty

    expect do
      post user_session_path,
           params: { user: { email: user.email, password: 'password' } }
    end.to change { user.reload.sign_in_count }.from(0).to(1)

    aggregate_failures do
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(root_path)
      expect(session[:pending_second_factor]).to be_blank
    end
  end

  it 'remember_meをpending sessionへ引き継ぐ' do
    user = create(:user)
    create_passkey_with_fake_client(user)

    post user_session_path,
         params: {
           user: {
             email: user.email,
             password: 'password',
             remember_me: '1'
           }
         }

    expect(session[:pending_second_factor]['remember_me']).to be(true)
  end
end
