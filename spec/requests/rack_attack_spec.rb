require 'rails_helper'

RSpec.describe 'Rack::Attack', type: :request do
  around do |example|
    original_enabled = Rack::Attack.enabled
    original_store = Rack::Attack.cache.store

    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.reset!

    example.run
  ensure
    Rack::Attack.reset!
    Rack::Attack.cache.store = original_store
    Rack::Attack.enabled = original_enabled
  end

  def remote_addr(ip)
    { 'REMOTE_ADDR' => ip }
  end

  def invalid_sign_in_params
    {
      user: {
        email: 'missing@example.com',
        password: 'wrong-password'
      }
    }
  end

  def expect_throttled_html_response
    retry_after = response.headers['Retry-After'].to_i
    retry_after_minutes = (retry_after / 60.0).ceil

    aggregate_failures do
      expect(response).to have_http_status(:too_many_requests)
      expect(retry_after).to be_positive
      expect(response.media_type).to eq('text/html')
      expect(response.body).to include(I18n.t('errors.too_many_requests.title'))
      expect(response.body).to include(I18n.t('errors.too_many_requests.description'))
      expect(response.body).to include(I18n.t('errors.too_many_requests.retry_after', minutes: retry_after_minutes))
      expect(response.body).to include(I18n.t('errors.too_many_requests.login_link'))
      expect(response.body).to include('href="/users/sign_in"')
      expect(response.body).to include('Error Code: 429')
      expect(response.body).to include('token-bg-page')
      expect(response.body).to include('glass-panel')
      expect(response.body).to include('material-symbols-outlined')
      expect(response.body).to include('timer')
      expect(response.body).not_to include('<style>')
      expect(response.body).not_to include('class="card"')
      expect(response.body).not_to include('rack.attack')
      expect(response.body).not_to include('REMOTE_ADDR')
    end
  end

  it 'expected throttle rules are configured' do
    expect(Rack::Attack.throttles.keys).to include(
      'requests/ip',
      'auth/sign_in/ip',
      'auth/password/ip',
      'auth/confirmation/ip',
      'auth/unlock/ip',
      'auth/registration/ip',
      'auth/guest_sign_in/ip',
      'receipts/upload/ip'
    )
  end

  it 'throttles sign in attempts by IP' do
    ip = '203.0.113.10'

    20.times do
      post user_session_path, params: invalid_sign_in_params, headers: remote_addr(ip)
      expect(response).not_to have_http_status(:too_many_requests)
    end

    post user_session_path, params: invalid_sign_in_params, headers: remote_addr(ip)

    expect_throttled_html_response
  end

  it 'keeps the sign in form accessible while throttling sign in posts' do
    ip = '203.0.113.13'

    20.times do
      post user_session_path, params: invalid_sign_in_params, headers: remote_addr(ip)
      expect(response).not_to have_http_status(:too_many_requests)
    end

    get new_user_session_path, headers: remote_addr(ip)

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('auth.sessions.form_title'))
    end

    post user_session_path,
      params: {
        user: {
          email: 'someone@example.com',
          password: 'password123'
        }
      },
      headers: remote_addr(ip)

    expect_throttled_html_response
  end

  it 'uses the same throttled page for other auth form POST limits without blocking their GET pages' do
    cases = [
      {
        ip: '203.0.113.14',
        limit: 10,
        get_path: new_user_password_path,
        post_path: user_password_path,
        params: { user: { email: '' } },
        get_copy: I18n.t('auth.passwords.new.form_title')
      },
      {
        ip: '203.0.113.15',
        limit: 10,
        get_path: new_user_confirmation_path,
        post_path: user_confirmation_path,
        params: { user: { email: '' } },
        get_copy: I18n.t('auth.confirmations.new.form_title')
      },
      {
        ip: '203.0.113.16',
        limit: 10,
        get_path: new_user_unlock_path,
        post_path: user_unlock_path,
        params: { user: { email: '' } },
        get_copy: I18n.t('auth.unlocks.new.form_title')
      },
      {
        ip: '203.0.113.17',
        limit: 10,
        get_path: new_user_registration_path,
        post_path: user_registration_path,
        params: { user: { email: '', password: '', password_confirmation: '' } },
        get_copy: I18n.t('auth.registrations.new.form_title')
      }
    ]

    cases.each do |form_case|
      form_case[:limit].times do
        post form_case[:post_path], params: form_case[:params], headers: remote_addr(form_case[:ip])
        expect(response).not_to have_http_status(:too_many_requests)
      end

      get form_case[:get_path], headers: remote_addr(form_case[:ip])

      aggregate_failures "#{form_case[:post_path]} GET remains accessible" do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(form_case[:get_copy])
      end

      post form_case[:post_path], params: form_case[:params], headers: remote_addr(form_case[:ip])

      expect_throttled_html_response
    end
  end

  it 'throttles receipt uploads by IP' do
    user = create(:user)
    ip = '203.0.113.11'
    sign_in user

    30.times do
      post upload_receipts_path, params: { receipt: { image: '' } }, headers: remote_addr(ip)
      expect(response).not_to have_http_status(:too_many_requests)
    end

    post upload_receipts_path, params: { receipt: { image: '' } }, headers: remote_addr(ip)

    expect_throttled_html_response
  end

  it 'blocks scanner paths and bans the IP after repeated hits' do
    ip = '203.0.113.12'

    3.times do
      get '/wp-login.php', headers: remote_addr(ip)
      expect(response).to have_http_status(:forbidden)
    end

    get root_path, headers: remote_addr(ip)

    aggregate_failures do
      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include(I18n.t('errors.forbidden.title'))
      expect(response.body).to include(I18n.t('errors.forbidden.description'))
    end
  end

  it 'returns JSON for throttled JSON requests' do
    env = Rack::MockRequest.env_for('/users/sign_in', 'HTTP_ACCEPT' => 'application/json')
    request = Rack::Attack::Request.new(env)
    request.env['rack.attack.match_data'] = { period: 5.minutes, epoch_time: Time.current.to_i }

    status, headers, body = Rack::Attack.throttled_responder.call(request)
    json = JSON.parse(body.join)

    aggregate_failures do
      expect(status).to eq(429)
      expect(headers['Retry-After'].to_i).to be_positive
      expect(headers['Content-Type']).to eq('application/json; charset=utf-8')
      expect(json).to include(
        'error' => I18n.t('errors.too_many_requests.title'),
        'message' => I18n.t('errors.too_many_requests.description'),
        'status' => 429,
        'retry_after' => headers['Retry-After'].to_i
      )
    end
  end
end
