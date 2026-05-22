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
    aggregate_failures do
      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers['Retry-After'].to_i).to be_positive
      expect(response.media_type).to eq('text/html')
      expect(response.body).to include(I18n.t('errors.too_many_requests.title'))
      expect(response.body).to include(I18n.t('errors.too_many_requests.description'))
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
        'status' => 429
      )
    end
  end
end
