require 'rails_helper'

RSpec.describe 'User security reauthentication', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:rate_limit_store) { ActiveSupport::Cache::MemoryStore.new }

  around do |example|
    ApplicationController.rate_limit_cache_store = rate_limit_store
    rate_limit_store.clear
    example.run
  ensure
    rate_limit_store.clear
    ApplicationController.rate_limit_cache_store = nil
  end

  it '非ログインではloginへ戻す' do
    get new_settings_security_reauthentication_path

    expect(response).to redirect_to(new_user_session_path)
  end

  it '本人確認画面はno-storeでpasswordを再表示しない' do
    sign_in user

    get new_settings_security_reauthentication_path

    document = Nokogiri::HTML(response.body)
    password_input = document.at_css("input[name='password']")

    aggregate_failures do
      expect(response).to have_http_status(:success)
      expect(response.headers['Cache-Control']).to include('no-store')
      expect(response.headers['Pragma']).to eq('no-cache')
      expect(password_input).to be_present
      expect(password_input['type']).to eq('password')
      expect(password_input['autocomplete']).to eq('current-password')
      expect(password_input['value']).to be_nil
    end
  end

  it '本人確認画面とvalidation失敗画面にSystemSettingsの有効期間を表示する' do
    create(
      :system_setting,
      key: 'security.user_reauth_window_minutes',
      value: SystemSettings.stored_value(10)
    )
    sign_in user

    get new_settings_security_reauthentication_path
    expect(response.body).to include('本人確認後10分間')
    expect(response.body).not_to include('本人確認後5分間')

    post settings_security_reauthentication_path, params: { password: 'wrong-local-secret' }

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('本人確認後10分間')
      expect(response.body).not_to include('本人確認後5分間')
    end
  end

  it '正しいpasswordで5分間のsession-bound本人確認を記録する' do
    sign_in user
    get new_settings_security_reauthentication_path(
      return_to: settings_security_path(anchor: 'passkeys')
    )

    post settings_security_reauthentication_path, params: { password: 'password' }

    context = session[:security_reauthentication]

    aggregate_failures do
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(settings_security_path(anchor: 'passkeys'))
      expect(context).to include(
        'user_id' => user.id,
        'session_version' => user.session_version,
        'method' => 'password'
      )
      expect(Time.zone.parse(context.fetch('authenticated_at'))).to be_within(1.second).of(Time.current)
      expect(Time.zone.parse(context.fetch('expires_at'))).to be_within(1.second).of(5.minutes.from_now)
      expect(response.headers['Cache-Control']).to include('no-store')
    end
  end

  it '誤passwordでは本人確認を記録せず422にする' do
    sign_in user

    post settings_security_reauthentication_path, params: { password: 'wrong-local-secret' }

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(session[:security_reauthentication]).to be_blank
      expect(response.body).to include(I18n.t('settings.security.reauthentication.messages.failed'))
      expect(response.body).not_to include('wrong-local-secret')
      expect(response.headers['Cache-Control']).to include('no-store')
    end
  end

  it '外部return_toを拒否してsecurity settingsへ戻す' do
    sign_in user
    get new_settings_security_reauthentication_path(return_to: 'https://evil.example.test/phish')

    post settings_security_reauthentication_path, params: { password: 'password' }

    expect(response).to redirect_to(settings_security_path)
  end

  it 'TTL経過後はpasskey challengeを発行しない' do
    sign_in user
    mark_security_reauthentication_fresh!(user)

    travel 6.minutes do
      post settings_passkeys_options_path, as: :json
    end

    aggregate_failures do
      expect(response).to have_http_status(:precondition_required)
      expect(session[:security_reauthentication]).to be_blank
      expect(session[:passkey_registration_challenge]).to be_blank
    end
  end

  it 'SystemSettingsで15分にした場合は10分後もfreshにする' do
    create(
      :system_setting,
      key: 'security.user_reauth_window_minutes',
      value: SystemSettings.stored_value(15)
    )
    sign_in user
    mark_security_reauthentication_fresh!(user)

    travel 10.minutes do
      post settings_passkeys_options_path, as: :json
    end

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(session[:security_reauthentication]).to be_present
      expect(session[:passkey_registration_challenge]).to be_present
    end
  end

  it 'window延長前に発行した本人確認を遡って延長しない' do
    setting = create(
      :system_setting,
      key: 'security.user_reauth_window_minutes',
      value: SystemSettings.stored_value(1)
    )
    sign_in user
    mark_security_reauthentication_fresh!(user)
    setting.update!(value: SystemSettings.stored_value(15))

    travel 2.minutes do
      post settings_passkeys_options_path, as: :json
    end

    aggregate_failures do
      expect(response).to have_http_status(:precondition_required)
      expect(session[:security_reauthentication]).to be_blank
      expect(session[:passkey_registration_challenge]).to be_blank
    end
  end

  it 'window短縮は発行済み本人確認へ即時適用する' do
    setting = create(
      :system_setting,
      key: 'security.user_reauth_window_minutes',
      value: SystemSettings.stored_value(15)
    )
    sign_in user
    mark_security_reauthentication_fresh!(user)
    setting.update!(value: SystemSettings.stored_value(1))

    travel 2.minutes do
      post settings_passkeys_options_path, as: :json
    end

    aggregate_failures do
      expect(response).to have_http_status(:precondition_required)
      expect(session[:security_reauthentication]).to be_blank
      expect(session[:passkey_registration_challenge]).to be_blank
    end
  end

  it '設定読込異常時は現行の5分へfail-safeする' do
    allow(SystemSettings).to receive(:limit_for).and_call_original
    allow(SystemSettings).to receive(:limit_for)
      .with('security.user_reauth_window_minutes')
      .and_raise(SystemSettings::ValidationError, 'invalid setting')
    sign_in user
    mark_security_reauthentication_fresh!(user)

    travel 6.minutes do
      post settings_passkeys_options_path, as: :json
    end

    aggregate_failures do
      expect(response).to have_http_status(:precondition_required)
      expect(session[:security_reauthentication]).to be_blank
      expect(session[:passkey_registration_challenge]).to be_blank
    end
  end

  it '別userへ切り替えたsessionでは本人確認を再利用しない' do
    other_user = create(:user)
    sign_in user
    mark_security_reauthentication_fresh!(user)
    sign_out user
    sign_in other_user

    post settings_passkeys_options_path, as: :json

    expect(response).to have_http_status(:precondition_required)
    expect(session[:passkey_registration_challenge]).to be_blank
  end

  it 'guestには本人確認を提供しない' do
    sign_in User.guest!

    get new_settings_security_reauthentication_path

    aggregate_failures do
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(settings_security_path)
      expect(session[:security_reauthentication]).to be_blank
    end
  end

  it 'unconfirmed userには本人確認を提供しない' do
    sign_in create(:user, :unconfirmed)

    get new_settings_security_reauthentication_path

    aggregate_failures do
      expect(response).to redirect_to(new_user_session_path)
      expect(session[:security_reauthentication]).to be_blank
    end
  end

  it 'userとIP単位で誤passwordを5回までに制限する' do
    sign_in user

    5.times do
      post settings_security_reauthentication_path,
           params: { password: 'wrong-password' },
           headers: { 'REMOTE_ADDR' => '198.51.100.10' }
      expect(response).to have_http_status(:unprocessable_content)
    end

    post settings_security_reauthentication_path,
         params: { password: 'wrong-password' },
         headers: { 'REMOTE_ADDR' => '198.51.100.10' }

    expect(response).to have_http_status(:too_many_requests)
  end
end
