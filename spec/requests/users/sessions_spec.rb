require 'rails_helper'
require 'webauthn/fake_client'

RSpec.describe 'User password sessions', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:client) { WebAuthn::FakeClient.new('http://localhost:3000') }

  def create_passkey_with_fake_client(user)
    options = Passkeys.registration_options(user: user)
    credential = client.create(challenge: options.challenge, rp_id: 'localhost', user_verified: true)

    Passkeys.verify_registration(user: user, credential: credential, challenge: options.challenge)
  end

  def create_confirmed_totp(user)
    create(:totp_credential, user: user, confirmed_at: Time.current)
  end

  def expect_no_dashboard_shell
    aggregate_failures do
      expect(response.body).not_to include('id="desktop-sidebar"')
      expect(response.body).not_to include('id="dashboard-header"')
      expect(response.body).not_to include('data-controller="search"')
    end
  end

  it 'passkey未登録userはpassword loginで従来通りログイン完了する' do
    user = create(:user)
    accept_current_legal_documents_for_request(user)

    expect do
      post user_session_path,
           params: { user: { email: user.email, password: 'password' } }
    end.to change { user.reload.sign_in_count }.from(0).to(1)
      .and change(UserSession, :count).by(1)

    user_session = UserSession.last

    aggregate_failures do
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq(I18n.t('auth.sessions.messages.signed_in'))
      expect(flash[:alert]).to be_nil
      expect(session[:pending_second_factor]).to be_blank
      expect(session[:user_session_version]).to eq(user.session_version)
      expect(session[:user_session_uid]).to be_present
      expect(session[:security_reauthentication]).to include(
        'user_id' => user.id,
        'session_version' => user.session_version,
        'method' => 'password'
      )
      expect(user_session.user).to eq(user)
      expect(user_session.sign_in_method).to eq('password')
      expect(user_session.session_uid_digest).not_to eq(session[:user_session_uid])
      expect(user.current_sign_in_at).to be_present
      expect(user.current_sign_in_ip).to be_present
    end

    get settings_path

    aggregate_failures do
      expect(response).to have_http_status(:success)
      expect(response.body).to include('id="desktop-sidebar"')
      expect(response.body).to include('id="dashboard-header"')
    end
  end

  it 'login_restricted中の一般ユーザーpassword loginは拒否する' do
    user = create(:user)
    create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))

    expect do
      post user_session_path,
           params: { user: { email: user.email, password: 'password' } }
    end.not_to change(UserSession, :count)

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:alert]).to eq(I18n.t('shared.maintenance_mode.body'))
      expect(flash[:notice]).to be_nil
      expect(session[:pending_second_factor]).to be_blank
      expect(session[:user_session_version]).to be_blank
      expect(session[:user_session_uid]).to be_blank
      expect(user.reload.sign_in_count).to eq(0)
      expect_no_dashboard_shell
    end
  end

  it 'login_restricted中でもadmin password loginは許可する' do
    admin = create(:user, :admin)
    create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))

    expect do
      post user_session_path,
           params: { user: { email: admin.email, password: 'password' } }
    end.to change { admin.reload.sign_in_count }.from(0).to(1)
      .and change(UserSession, :count).by(1)

    aggregate_failures do
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq(I18n.t('auth.sessions.messages.signed_in'))
      expect(flash[:alert]).to be_nil
      expect(session[:pending_second_factor]).to be_blank
      expect(session[:user_session_version]).to eq(admin.session_version)
      expect(session[:user_session_uid]).to be_present
    end
  end

  it 'unconfirmed userは2FA要素があってもpassword loginでpendingへ進まない' do
    user = create(:user, :unconfirmed)
    create(:passkey, user: user)
    create_confirmed_totp(user)

    expect do
      post user_session_path,
           params: { user: { email: user.email, password: 'password' } }
    end.not_to change(UserSession, :count)

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(session[:pending_second_factor]).to be_blank
      expect(session[:user_session_version]).to be_blank
      expect(session[:user_session_uid]).to be_blank
      expect(flash[:alert]).to eq(I18n.t('devise.failure.unconfirmed'))
      expect(flash[:notice]).to be_nil
      expect(response.body).not_to include(I18n.t('auth.two_factor.messages.pending_notice'))
      expect(response.body).not_to include(I18n.t('auth.sessions.messages.signed_in'))
      expect_no_dashboard_shell
      expect(user.reload.sign_in_count).to eq(0)
    end
  end

  it 'locked userは正しいpasswordでもnoticeなしで拒否される' do
    user = create(:user)
    user.lock_access!

    expect do
      post user_session_path,
           params: { user: { email: user.email, password: 'password' } }
    end.not_to change(UserSession, :count)

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:alert]).to eq(I18n.t('devise.failure.locked'))
      expect(flash[:notice]).to be_nil
      expect(session[:pending_second_factor]).to be_blank
      expect(session[:user_session_version]).to be_blank
      expect(session[:user_session_uid]).to be_blank
      expect(response.body).not_to include(I18n.t('auth.sessions.messages.signed_in'))
      expect_no_dashboard_shell
      expect(user.reload.sign_in_count).to eq(0)
    end
  end

  it 'password誤りではnoticeなしでdashboard shellを表示しない' do
    user = create(:user)

    expect do
      post user_session_path,
           params: { user: { email: user.email, password: 'wrong-password' } }
    end.not_to change(UserSession, :count)

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:alert]).to be_present
      expect(flash[:notice]).to be_nil
      expect(session[:pending_second_factor]).to be_blank
      expect(session[:user_session_version]).to be_blank
      expect(session[:user_session_uid]).to be_blank
      expect(response.body).not_to include(I18n.t('auth.sessions.messages.signed_in'))
      expect_no_dashboard_shell
      expect(user.reload.sign_in_count).to eq(0)
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
      expect(session[:security_reauthentication]).to be_blank
      expect(user.current_sign_in_at).to be_blank
    end

    get settings_path

    expect(response).to redirect_to(new_user_session_path)
  end

  it 'TOTPのみ登録済みuserはpassword login後にTOTP step-upへ進む' do
    user = create(:user)
    create_confirmed_totp(user)

    post user_session_path,
         params: { user: { email: user.email, password: 'password' } }

    pending = session[:pending_second_factor]

    aggregate_failures do
      expect(response).to redirect_to(users_two_factor_totp_path)
      expect(pending['user_id']).to eq(user.id)
      expect(pending['allowed_methods']).to eq([ 'totp' ])
      expect(user.reload.sign_in_count).to eq(0)
    end
  end

  it 'recovery codeのみ登録済みuserはpassword login後にrecovery code step-upへ進む' do
    user = create(:user)
    TwoFactor.generate_recovery_codes_for(user: user)

    post user_session_path,
         params: { user: { email: user.email, password: 'password' } }

    pending = session[:pending_second_factor]

    aggregate_failures do
      expect(response).to redirect_to(users_two_factor_recovery_code_path)
      expect(pending['allowed_methods']).to eq([ 'recovery_code' ])
      expect(user.reload.sign_in_count).to eq(0)
    end
  end

  it 'passkeyとTOTP登録済みuserはpasskeyを主導線にしてfallback methodをpendingに持つ' do
    user = create(:user)
    create_passkey_with_fake_client(user)
    create_confirmed_totp(user)
    TwoFactor.generate_recovery_codes_for(user: user)

    post user_session_path,
         params: { user: { email: user.email, password: 'password' } }

    aggregate_failures do
      expect(response).to redirect_to(users_two_factor_passkey_path)
      expect(session[:pending_second_factor]['allowed_methods']).to eq(%w[passkey totp recovery_code])
    end
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
      expect(session[:user_session_version]).to eq(user.session_version)
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

  it 'session version一致なら通常アクセスできる' do
    user = create(:user)
    accept_current_legal_documents_for_request(user)

    post user_session_path,
         params: { user: { email: user.email, password: 'password' } }

    get settings_path

    expect(response).to have_http_status(:success)
  end

  it 'request時に現在sessionのlast_seen_atを更新する' do
    user = create(:user)
    accept_current_legal_documents_for_request(user)

    post user_session_path,
         params: { user: { email: user.email, password: 'password' } }
    user_session = UserSession.last
    user_session.update!(last_seen_at: 10.minutes.ago)

    get settings_path

    aggregate_failures do
      expect(response).to have_http_status(:success)
      expect(user_session.reload.last_seen_at).to be_within(1.second).of(Time.current)
    end
  end

  it 'last_seen_atが5分未満なら更新しない' do
    user = create(:user)
    accept_current_legal_documents_for_request(user)

    post user_session_path,
         params: { user: { email: user.email, password: 'password' } }
    user_session = UserSession.last
    recent_seen_at = 1.minute.ago.change(usec: 0)
    user_session.update!(last_seen_at: recent_seen_at)

    get settings_path

    aggregate_failures do
      expect(response).to have_http_status(:success)
      expect(user_session.reload.last_seen_at.to_i).to eq(recent_seen_at.to_i)
    end
  end

  it 'session version不一致ならsign outしてログインへ戻す' do
    user = create(:user)

    post user_session_path,
         params: { user: { email: user.email, password: 'password' } }
    user_session = UserSession.last
    stale_seen_at = 10.minutes.ago.change(usec: 0)
    user_session.update!(last_seen_at: stale_seen_at)
    user.update!(session_version: user.session_version + 1)

    get settings_path

    aggregate_failures do
      expect(response).to redirect_to(new_user_session_path)
      expect(session[:user_session_version]).to be_blank
      expect(user_session.reload.last_seen_at.to_i).to eq(stale_seen_at.to_i)
    end
  end

  it 'session revoke後の次requestでsign outしてログインへ戻す' do
    admin = create(:user, :admin)
    user = create(:user)

    post user_session_path,
         params: { user: { email: user.email, password: 'password' } }
    expect(session[:user_session_version]).to eq(0)

    result = SystemOperations.execute_user_operation(
      operation: 'revoke_sessions',
      user: user,
      actor: admin,
      reason: 'device lost support request',
      request: nil,
      reauthentication: { method: 'passkey', reauthenticated_at: Time.current },
      confirmation: 'REVOKE SESSIONS'
    )

    aggregate_failures do
      expect(result).to be_success
      expect(user.reload.session_version).to eq(1)
    end

    get settings_path

    aggregate_failures do
      expect(response).to redirect_to(new_user_session_path)
      expect(session[:user_session_version]).to be_blank
    end
  end

  it 'session version nilの既存セッションは現在値で補完する' do
    user = create(:user)
    sign_in user

    get settings_path

    aggregate_failures do
      expect(response).to have_http_status(:success)
      expect(session[:user_session_version]).to eq(user.session_version)
    end
  end

  it 'current_userなしでは何もしない' do
    get new_user_session_path

    aggregate_failures do
      expect(response).to have_http_status(:success)
      expect(session[:user_session_version]).to be_blank
    end
  end

  it 'logoutでsession versionを削除する' do
    user = create(:user)

    post user_session_path,
         params: { user: { email: user.email, password: 'password' } }
    expect(session[:user_session_version]).to eq(user.session_version)
    user_session = UserSession.last

    delete destroy_user_session_path

    aggregate_failures do
      expect(session[:user_session_version]).to be_blank
      expect(session[:user_session_uid]).to be_blank
      expect(user_session.reload.signed_out_at).to be_present
    end
  end
end
