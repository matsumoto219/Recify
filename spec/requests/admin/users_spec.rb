require 'rails_helper'

RSpec.describe 'Admin users', type: :request do
  include ActiveJob::TestHelper

  around do |example|
    original_show_exceptions = Rails.application.env_config['action_dispatch.show_exceptions']
    original_show_detailed_exceptions = Rails.application.env_config['action_dispatch.show_detailed_exceptions']
    original_adapter = ActiveJob::Base.queue_adapter

    Rails.application.env_config['action_dispatch.show_exceptions'] = :all
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = false
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs

    example.run
  ensure
    clear_enqueued_jobs
    ActiveJob::Base.queue_adapter = original_adapter
    Rails.application.env_config['action_dispatch.show_exceptions'] = original_show_exceptions
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = original_show_detailed_exceptions
  end

  def comparable_headers
    response.headers.to_h.except('x-request-id', 'x-runtime')
  end

  def expect_no_admin_side_effects(previous_audit_count)
    analysis_jobs = [ ReceiptOcrJob, ReceiptAiEnrichmentJob, ReceiptFinalizeJob ]

    expect(enqueued_jobs.select { |job| analysis_jobs.include?(job[:job]) }).to be_empty
    expect(AuditLog.count).to eq(previous_audit_count)
    expect(SystemOperations).not_to have_received(:execute_receipt_analysis_cleanup)
    expect(SystemOperations).not_to have_received(:update_setting)
    expect(SystemOperations).not_to have_received(:execute_user_operation)
    expect(Analysis::RetryService).not_to have_received(:call)
  end

  before do
    allow(SystemOperations).to receive(:execute_receipt_analysis_cleanup)
    allow(SystemOperations).to receive(:update_setting)
    allow(SystemOperations).to receive(:execute_user_operation)
    allow(Analysis::RetryService).to receive(:call)
  end

  describe 'GET /admin/users' do
    it '非ログインユーザーはログインへリダイレクトする' do
      get admin_users_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it '一般ユーザーには既存404と同じbody/headerを返す' do
      user = create(:user)
      sign_in user

      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      sign_in user
      get admin_users_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).not_to include('ユーザー管理')
      end
    end

    it 'adminユーザーはindexを閲覧でき、navigationにユーザー管理が出る' do
      admin = create(:user, :admin)
      target = create(:user, email: 'target-user@example.com')
      create(:passkey, user: target)
      create_list(:receipt, 2, user: target)
      previous_audit_count = AuditLog.count
      sign_in admin

      get admin_users_path
      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('ユーザー管理')
        expect(response.body).to include('target-user@example.com')
        expect(response.body).to include(admin_user_path(target))
        expect(document.at_css("[data-admin-user-passkeys-count=\"#{target.id}\"]").text).to eq('1')
        expect(document.at_css("[data-admin-user-receipts-count=\"#{target.id}\"]").text).to eq('2')
        expect(response.body).to include('解析run管理')
        expect(response.body).to include('監査ログ')
        expect(response.body).not_to include('credential_id')
        expect(response.body).not_to include('public_key')
        expect(response.body).not_to include('challenge')
        expect_no_admin_side_effects(previous_audit_count)
      end
    end

    it 'filter paramsをAdmin queryへ渡す' do
      admin = create(:user, :admin)
      sign_in admin
      allow(Admin).to receive(:users).and_call_original

      get admin_users_path,
          params: {
            email: 'target',
            admin: 'true',
            guest: 'false',
            confirmed: 'true',
            locked: 'false',
            has_passkey: 'true',
            limit: '10',
            offset: '20'
          }

      expect(Admin).to have_received(:users).with(
        email: 'target',
        admin: 'true',
        guest: 'false',
        confirmed: 'true',
        locked: 'false',
        has_passkey: 'true',
        limit: '10',
        offset: '20'
      )
    end

    it 'paginationのnext/prevがfilter paramsを維持する' do
      admin = create(:user, :admin)
      sign_in admin
      Array.new(3) do |index|
        user = create(:user, email: "passkey-user-#{index}@example.com")
        create(:passkey, user: user)
      end

      get admin_users_path,
          params: {
            has_passkey: 'true',
            limit: '1',
            offset: '1'
          }

      document = Nokogiri::HTML(response.body)
      previous_href = document.css('a').find { |link| link.text.strip == '前へ' }['href']
      next_href = document.css('a').find { |link| link.text.strip == '次へ' }['href']
      previous_query = Rack::Utils.parse_nested_query(URI.parse(previous_href).query)
      next_query = Rack::Utils.parse_nested_query(URI.parse(next_href).query)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('3件中 2-2件を表示')
        expect(previous_query).to include('has_passkey' => 'true', 'limit' => '1', 'offset' => '0')
        expect(next_query).to include('has_passkey' => 'true', 'limit' => '1', 'offset' => '2')
      end
    end
  end

  describe 'GET /admin/users/:id' do
    it 'adminユーザーはshowを閲覧でき、security/passkey/receipt/audit状態を確認できる' do
      admin = create(:user, :admin)
      user = create(
        :user,
        email: 'show-user@example.com',
        current_sign_in_at: 1.hour.ago,
        last_sign_in_at: 2.hours.ago,
        current_sign_in_ip: '203.0.113.20',
        last_sign_in_ip: '203.0.113.21',
        sign_in_count: 3,
        failed_attempts: 1
      )
      create(:passkey, user: user, credential_id: 'hidden-credential-id', public_key: 'HIDDEN PUBLIC KEY', last_used_at: 30.minutes.ago)
      create_list(:receipt, 2, user: user)
      active_session = UserSession.create!(
        user: user,
        session_uid_digest: 'hidden-session-digest',
        session_version: user.session_version,
        started_at: 2.hours.ago,
        last_seen_at: 15.minutes.ago,
        ip_address: '203.0.113.40',
        user_agent: 'Support Browser',
        sign_in_method: 'password'
      )
      UserSession.create!(
        user: user,
        session_uid_digest: SecureRandom.hex(32),
        session_version: user.session_version + 1,
        started_at: 1.hour.ago,
        last_seen_at: 10.minutes.ago,
        ip_address: '203.0.113.41',
        user_agent: 'Old Version Browser',
        sign_in_method: 'passkey'
      )
      create(:audit_log, actor_user: user, action: 'receipt_analysis.ai_retry', target_uid: 'rcpt_user_show')
      previous_audit_count = AuditLog.count
      previous_user_session_count = UserSession.count
      sign_in admin

      get admin_user_path(user)
      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('ユーザー詳細')
        expect(response.body).to include('show-user@example.com')
        expect(response.body).to include('203.0.113.20')
        expect(response.body).to include('203.0.113.21')
        expect(response.body).to include('receipt_analysis.ai_retry')
        expect(response.body).to include('rcpt_user_show')
        expect(document.at_css('[data-admin-user-passkeys-count]').text).to eq('1')
        expect(document.at_css('[data-admin-user-receipts-count]').text).to eq('2')
        expect(document.at_css('[data-admin-user-active-sessions-count]').text).to eq('1')
        expect(response.body).to include(I18n.l(active_session.last_seen_at, format: :short))
        expect(response.body).to include('203.0.113.40')
        expect(response.body).to include('Support Browser')
        expect(response.body).not_to include('203.0.113.41')
        expect(response.body).not_to include('Old Version Browser')
        expect(response.body).to include(admin_receipt_analysis_runs_path(user_id: user.id))
        expect(response.body).to include(admin_audit_logs_path(actor_user_id: user.id))
        expect(response.body).not_to include('hidden-credential-id')
        expect(response.body).not_to include('HIDDEN PUBLIC KEY')
        expect(response.body).not_to include('hidden-session-digest')
        expect(response.body).not_to include('challenge')
        expect(response.body).not_to include('cookie')
        expect(response.body).not_to include('remember_token')
        expect(response.body).not_to include('raw_response')
        expect(response.body).not_to include('FULL PROMPT')
        expect(response.body).not_to include('SECRET')
        expect(UserSession.count).to eq(previous_user_session_count)
        expect_no_admin_side_effects(previous_audit_count)
      end
    end

    it '存在しないidは既存404へ流す' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_user_path(999_999)

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to include(I18n.t('errors.not_found.title'))
      end
    end

    it '管理操作カードを表示するが、再認証前は実行フォームを表示しない' do
      admin = create(:user, :admin)
      user = create(:user)
      sign_in admin

      get admin_user_path(user)

      expect(response).to have_http_status(:success)
      expect(response.body).to include('管理操作')
      expect(response.body).to include(new_admin_passkey_reauthentication_path(return_to: admin_user_path(user)))
      expect(response.body).not_to include(lock_operation_admin_user_path(user))
    end

    it 'UIに開発者向け文言を出さない' do
      admin = create(:user, :admin)
      user = create(:user)
      sign_in admin

      get admin_user_path(user)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/v1\.0後|未実装|TODO|service\/facade|payload|development\/test|production/)
        expect(response.body).not_to include('権限変更')
        expect(response.body).not_to include('削除する')
        expect(response.body).not_to include('パスキー削除')
      end
    end
  end
end
