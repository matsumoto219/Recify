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

  def turbo_request_headers(ip)
    remote_addr(ip).merge(
      'ACCEPT' => 'text/vnd.turbo-stream.html, text/html, application/xhtml+xml'
    )
  end

  def invalid_sign_in_params
    {
      user: {
        email: 'missing@example.com',
        password: 'wrong-password'
      }
    }
  end

  def scanner_request_for(path)
    Rack::Attack::Request.new(Rack::MockRequest.env_for(path))
  end

  def expect_throttled_html_response
    retry_after = response.headers['Retry-After'].to_i
    retry_after_minutes = (retry_after / 60.0).ceil

    aggregate_failures do
      expect(response).to have_http_status(:too_many_requests)
      expect(retry_after).to be_positive
      expect(response.headers['Turbo-Visit-Control']).to eq('reload')
      expect(response.media_type).to eq('text/html')
      expect(response.body).to include(I18n.t('errors.too_many_requests.title'))
      expect(response.body).to include(I18n.t('errors.too_many_requests.description'))
      expect(response.body).to include(I18n.t('errors.too_many_requests.retry_after', minutes: retry_after_minutes))
      expect(response.body).to include(I18n.t('errors.too_many_requests.back_link'))
      expect(response.body).not_to include('ログイン画面へ戻る')
      expect(response.body).to include('href="/"')
      expect(response.body).to include('data-controller="history-back"')
      expect(response.body).to include('data-action="history-back#go"')
      expect(response.body).to include('Error Code: 429')
      expect(response.body).to include('token-bg-page')
      expect(response.body).to include('glass-panel')
      expect(response.body).to include('material-symbols-outlined')
      expect(response.body).to include('timer')
      expect(response.body).to include('type="importmap"')
      expect(response.body).to include('@hotwired/turbo-rails')
      expect(response.body).not_to include('<style>')
      expect(response.body).not_to include('class="card"')
      expect(response.body).not_to include('rack.attack')
      expect(response.body).not_to include('REMOTE_ADDR')
    end
  end

  def expect_blocklisted_html_response(path: nil)
    aggregate_failures do
      expect(response).to have_http_status(:forbidden)
      expect(response.headers['Turbo-Visit-Control']).to eq('reload')
      expect(response.media_type).to eq('text/html')
      expect(response.body).to include(I18n.t('errors.forbidden.title'))
      expect(response.body).to include(I18n.t('errors.forbidden.description'))
      expect(response.body).to include('Error Code: 403')
      expect(response.body).to include('token-bg-page')
      expect(response.body).to include('glass-panel')
      expect(response.body).to include('material-symbols-outlined')
      expect(response.body).to include('block')
      expect(response.body).to include('type="importmap"')
      expect(response.body).to include('@hotwired/turbo-rails')
      expect(response.body).not_to include('<style>')
      expect(response.body).not_to include(I18n.t('errors.common.signed_out_primary_cta'))
      expect(response.body).not_to include(new_user_session_path)
      expect(response.body).not_to include(I18n.t('errors.too_many_requests.back_link'))
      expect(response.body).not_to include('rack.attack')
      expect(response.body).not_to include('REMOTE_ADDR')
      expect(response.body).not_to include('scanner:')
      expect(response.body).not_to include('fail2ban')
      expect(response.body).not_to include(path) if path.present?
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
      'receipts/upload/ip',
      'receipts/processing_cards/ip'
    )
  end

  it 'processing card pollingを通常リクエスト枠から分離して専用上限で保護する' do
    request = Rack::Attack::Request.new(
      Rack::MockRequest.env_for(
        processing_cards_receipts_path,
        'REQUEST_METHOD' => 'GET',
        'REMOTE_ADDR' => '203.0.113.41'
      )
    )
    throttle = Rack::Attack.throttles.fetch('receipts/processing_cards/ip')

    aggregate_failures do
      expect(Rack::Attack.throttleable_request?(request)).to be(false)
      expect(Rack::Attack.receipt_processing_cards_request?(request)).to be(true)
      expect(throttle.limit).to eq(600)
      expect(throttle.period).to eq(5.minutes)
      expect(throttle.block.call(request)).to eq('203.0.113.41')
    end
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

  it 'records throttled sign in attempts without credential payload' do
    ip = '203.0.113.30'

    20.times do
      post user_session_path, params: invalid_sign_in_params, headers: remote_addr(ip)
      expect(response).not_to have_http_status(:too_many_requests)
    end

    expect {
      post user_session_path, params: invalid_sign_in_params, headers: remote_addr(ip)
    }.to change(SecurityEvent.where(event_type: 'rate_limit_triggered'), :count).by(1)

    event = SecurityEvent.last

    aggregate_failures do
      expect_throttled_html_response
      expect(event).to have_attributes(
        severity: 'medium',
        path: user_session_path,
        method: 'POST',
        matched_rule: 'auth/sign_in/ip'
      )
      expect(event.ip_address.to_s).to eq(ip)
      expect(event.payload_excerpt).to be_blank
      expect(event.metadata.to_json).not_to include('wrong-password', 'missing@example.com')
      expect(SecurityIpAction.last).to have_attributes(
        ip_address: IPAddr.new(ip),
        action_type: 'rate_limit_triggered',
        source: 'rack_attack',
        status: 'observed',
        matched_rule: 'auth/sign_in/ip'
      )
    end
  end

  it 'asks Turbo form submissions to reload the throttled HTML page' do
    ip = '203.0.113.18'

    20.times do
      post user_session_path, params: invalid_sign_in_params, headers: turbo_request_headers(ip)
      expect(response).not_to have_http_status(:too_many_requests)
    end

    post user_session_path, params: invalid_sign_in_params, headers: turbo_request_headers(ip)

    aggregate_failures do
      expect_throttled_html_response
      expect(response.headers['Retry-After'].to_i).to be_positive
      expect(response.headers['Turbo-Visit-Control']).to eq('reload')
    end
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
      expect_blocklisted_html_response(path: 'wp-login.php')
    end

    get root_path, headers: remote_addr(ip)

    aggregate_failures do
      expect_blocklisted_html_response
      expect(SecurityIpAction.where(ip_address: ip, action_type: 'scanner_restriction')).to exist
      expect(SecurityIpAction.where(ip_address: ip, matched_rule: 'fail2ban/scanner_paths').sum(:count)).to be >= 3
    end
  end

  it 'blocks manually restricted IP addresses from the database' do
    ip = '8.8.8.8'
    create(:security_ip_block, ip_address: ip)

    get root_path, headers: remote_addr(ip)

    aggregate_failures do
      expect_blocklisted_html_response
      expect(SecurityEvent.last).to have_attributes(
        event_type: 'rate_limit_triggered',
        matched_rule: 'manual/ip_blocks'
      )
      expect(SecurityEvent.last.ip_address.to_s).to eq(ip)
      expect(SecurityIpAction.where(ip_address: ip, matched_rule: 'manual/ip_blocks')).not_to exist
    end
  end

  it 'treats Rails and secret file probes as scanner requests' do
    paths = [
      '/.git/config',
      '/.env.local',
      '/.env.production',
      '/config/master.key',
      '/backup.sql',
      '/dump-20260628.sql',
      '/backup-20260628.tar.gz',
      '/assets/application.css.bak'
    ]

    aggregate_failures do
      paths.each do |path|
        expect(Rack::Attack.scanner_request?(scanner_request_for(path))).to be(true), "#{path} should be a scanner path"
      end
    end
  end

  it 'treats PHP, WordPress, package, and framework config probes as scanner requests' do
    paths = [
      '/ccc.php',
      '/miru.php',
      '/adminer.php',
      '/wp-content/plugins/example/readme.txt',
      '/wp-includes/js/wp-emoji-release.min.js',
      '/composer.json',
      '/composer.lock',
      '/package.json',
      '/yarn.lock',
      '/pnpm-lock.yaml',
      '/vite.config.js',
      '/next.config.mjs',
      '/nuxt.config.ts',
      '/firebase.json',
      '/amplify.yml'
    ]

    aggregate_failures do
      paths.each do |path|
        expect(Rack::Attack.scanner_request?(scanner_request_for(path))).to be(true), "#{path} should be a scanner path"
      end
    end
  end

  it 'treats encoded path traversal probes as scanner requests' do
    paths = [
      '/../../etc/passwd',
      '/?file=..%2F..%2Fetc%2Fpasswd',
      '/?path=%252e%252e%252fconfig%252fmaster.key',
      '/download?file=..%5Cwindows%5Cwin.ini'
    ]

    aggregate_failures do
      paths.each do |path|
        expect(Rack::Attack.scanner_request?(scanner_request_for(path))).to be(true), "#{path} should be a scanner path"
      end
    end
  end

  it 'treats Rails debug and mounted app probes as scanner requests' do
    paths = [
      '/rails/info/routes',
      '/rails/info/properties',
      '/rails/mailers',
      '/rails/conductor',
      '/sidekiq',
      '/admin/sidekiq',
      '/solid_queue',
      '/admin/solid_queue'
    ]

    aggregate_failures do
      paths.each do |path|
        expect(Rack::Attack.scanner_request?(scanner_request_for(path))).to be(true), "#{path} should be a scanner path"
      end
    end
  end

  it 'does not treat normal application paths as scanner requests' do
    paths = [
      '/admin',
      '/admin/security_events',
      '/.well-known/security.txt',
      '/cable',
      '/robots.txt',
      '/sitemap.xml',
      '/up',
      '/terms',
      '/privacy',
      '/users/sign_in',
      '/contact',
      '/receipts',
      '/settings',
      '/notifications'
    ]

    aggregate_failures do
      paths.each do |path|
        expect(Rack::Attack.scanner_request?(scanner_request_for(path))).to be(false), "#{path} should not be a scanner path"
      end
    end
  end

  it 'blocks new scanner probes with the existing fail2ban response' do
    ip = '203.0.113.19'

    3.times do
      get '/.git/config', headers: remote_addr(ip)
      expect_blocklisted_html_response(path: '.git/config')
    end

    get root_path, headers: remote_addr(ip)

    expect_blocklisted_html_response
  end

  it 'blocks Rails debug probes with the existing fail2ban response' do
    ip = '203.0.113.20'

    3.times do
      get '/rails/info/routes', headers: remote_addr(ip)
      expect_blocklisted_html_response(path: 'rails/info/routes')
    end

    get root_path, headers: remote_addr(ip)

    expect_blocklisted_html_response
  end

  it 'does not count normal admin pages as admin probes' do
    normal_admin_paths = [
      '/admin',
      '/admin/',
      '/admin/users',
      '/admin/users/1',
      '/admin/audit_logs',
      '/admin/audit_logs/26',
      '/admin/receipt_analysis_runs',
      '/admin/receipt_analysis_runs/run_abc',
      '/admin/contact_requests',
      '/admin/receipt_analysis_cleanup',
      '/admin/external_services/status'
    ]

    aggregate_failures do
      normal_admin_paths.each do |path|
        request = scanner_request_for(path)

        expect(Rack::Attack.admin_probe_request?(request)).to be(false), "#{path} should not be an admin probe"
        expect(Rack::Attack.scanner_request?(request)).to be(false), "#{path} should not be a scanner path"
      end
    end
  end

  it 'counts suspicious admin probes separately and only blocks after the higher threshold' do
    ip = '203.0.113.21'

    Rack::Attack::ADMIN_PROBE_MAXRETRY.times do
      get '/admin/login', headers: remote_addr(ip)
      expect(response).not_to have_http_status(:forbidden)
    end

    get '/admin.php', headers: remote_addr(ip)

    expect_blocklisted_html_response(path: 'admin.php')
  end

  it 'treats suspicious admin paths as admin probes' do
    suspicious_admin_paths = [
      '/admin/login',
      '/admin.php',
      '/adminer',
      '/administrator',
      '/admin/login.php',
      '/admin/index.php',
      '/admin/admin.php',
      '/cpanel',
      '/webadmin',
      '/manager',
      '/cms',
      '/wp-admin',
      '/wp-admin/',
      '/wp-login.php'
    ]

    aggregate_failures do
      suspicious_admin_paths.each do |path|
        expect(Rack::Attack.admin_probe_request?(scanner_request_for(path))).to be(true), "#{path} should be an admin probe"
      end
    end
  end

  it 'does not count the admin service status JSON polling endpoint as an admin probe' do
    request = Rack::Attack::Request.new(
      Rack::MockRequest.env_for('/admin/external_services/status', 'HTTP_ACCEPT' => 'application/json')
    )

    aggregate_failures do
      expect(Rack::Attack.admin_probe_request?(request)).to be(false)
      expect(Rack::Attack.scanner_request?(request)).to be(false)
    end
  end

  it 'does not count direct HTML hits to the admin service status endpoint as admin probes' do
    request = scanner_request_for('/admin/external_services/status')

    expect(Rack::Attack.admin_probe_request?(request)).to be(false)
  end

  it 'does not block signed-in admin users while they browse normal admin pages repeatedly' do
    admin = create(:user, :admin)
    audit_log = create(:audit_log)
    ip = '203.0.113.24'
    sign_in admin

    [
      admin_audit_log_path(audit_log),
      admin_users_path,
      admin_receipt_analysis_runs_path
    ].each do |path|
      30.times do
        get path, headers: remote_addr(ip)
        expect(response).not_to have_http_status(:forbidden)
      end
    end

    get root_path, headers: remote_addr(ip)
    expect(response).not_to have_http_status(:forbidden)

    get receipts_path, headers: remote_addr(ip)
    expect(response).not_to have_http_status(:forbidden)
  end

  it 'blocks repeated ActiveStorage direct upload probes' do
    ip = '203.0.113.22'

    3.times do
      post '/rails/active_storage/direct_uploads', headers: remote_addr(ip)
      expect_blocklisted_html_response(path: 'rails/active_storage/direct_uploads')
    end

    get root_path, headers: remote_addr(ip)

    expect_blocklisted_html_response
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
      expect(headers).not_to include('Turbo-Visit-Control')
      expect(json).to include(
        'error' => I18n.t('errors.too_many_requests.title'),
        'message' => I18n.t('errors.too_many_requests.description'),
        'status' => 429,
        'retry_after' => headers['Retry-After'].to_i
      )
    end
  end

  it 'returns JSON for blocklisted JSON requests' do
    env = Rack::MockRequest.env_for('/wp-login.php', 'HTTP_ACCEPT' => 'application/json')
    request = Rack::Attack::Request.new(env)

    status, headers, body = Rack::Attack.blocklisted_responder.call(request)
    json = JSON.parse(body.join)

    aggregate_failures do
      expect(status).to eq(403)
      expect(headers['Content-Type']).to eq('application/json; charset=utf-8')
      expect(headers).not_to include('Turbo-Visit-Control')
      expect(json).to include(
        'error' => I18n.t('errors.forbidden.title'),
        'message' => I18n.t('errors.forbidden.description'),
        'status' => 403
      )
      expect(body.join).not_to include('wp-login.php')
      expect(body.join).not_to include('scanner:')
      expect(body.join).not_to include('fail2ban')
    end
  end
end
