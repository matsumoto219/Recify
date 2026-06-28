require 'rails_helper'

RSpec.describe 'Admin security events', type: :request do
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

  def stub_fresh_admin_reauthentication
    allow_any_instance_of(Admin::SecurityEventsController).to receive(:admin_passkey_reauthenticated?).and_return(true)
    allow_any_instance_of(Admin::SecurityEventsController).to receive(:admin_reauthentication_context).and_return(
      method: 'passkey',
      reauthenticated_at: Time.current
    )
  end

  describe 'GET /admin/security_events' do
    it '非ログインユーザーには既存404と同じbody/headerを返す' do
      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      get admin_security_events_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).not_to include('セキュリティイベント')
      end
    end

    it '一般ユーザーには既存404と同じbody/headerを返す' do
      user = create(:user)
      sign_in user

      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      sign_in user
      get admin_security_events_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).not_to include('セキュリティイベント')
      end
    end

    it 'adminユーザーはindexを閲覧できる' do
      admin = create(:user, :admin)
      event = create(:security_event, event_type: 'xss_attempt', severity: 'high', path: '/receipts')
      sign_in admin

      get admin_security_events_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('セキュリティイベント')
        expect(response.body).to include('イベント種別')
        expect(response.body).to include('安全な抜粋')
        expect(response.body).to include(event.event_type)
        expect(response.body).to include('/receipts')
        expect(response.body).to include(admin_security_event_path(event))
      end
    end

    it 'filter paramsをAdmin queryへ渡す' do
      admin = create(:user, :admin)
      sign_in admin
      allow(Admin).to receive(:security_events).and_call_original

      get admin_security_events_path,
          params: {
            actor_user_id: '1',
            event_type: 'xss_attempt',
            severity: 'high',
            ip_address: '203.0.113.10',
            request_id: 'req-filter',
            path: '/receipts',
            matched_rule: 'script_tag',
            state: 'open',
            created_from: '2026-05-01T00:00',
            created_to: '2026-05-26T23:59',
            limit: '10',
            offset: '20'
          }

      expect(Admin).to have_received(:security_events).with(
        actor_user_id: '1',
        event_type: 'xss_attempt',
        severity: 'high',
        ip_address: '203.0.113.10',
        request_id: 'req-filter',
        path: '/receipts',
        matched_rule: 'script_tag',
        state: 'open',
        created_from: '2026-05-01T00:00',
        created_to: '2026-05-26T23:59',
        limit: '10',
        offset: '20'
      )
    end
  end

  describe 'GET /admin/security_events/:id' do
    it 'safe excerptをescapeして表示する' do
      admin = create(:user, :admin)
      event = create(
        :security_event,
        event_type: 'xss_attempt',
        matched_rule: 'script_tag',
        payload_excerpt: '<script>alert(1)</script>',
        user_agent: 'https://scanner.example.test/<script>alert(1)</script>',
        request_id: 'req-security-event-xss',
        metadata: { 'field' => 'q', 'sample' => '<img src=x onerror=alert(1)>' }
      )
      sign_in admin

      get admin_security_event_path(event)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('セキュリティイベント詳細')
        expect(response.body).to include('安全な抜粋')
        expect(response.body).to include('検知ルール')
        expect(response.body).to include('User-Agent文字列')
        expect(response.body).to include('https://scanner.example.test/&lt;script&gt;alert(1)&lt;/script&gt;')
        expect(response.body).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
        expect(response.body).not_to include('<script>alert(1)</script>')
        expect(response.body).not_to include('<a href="https://scanner.example.test/')
        expect(response.body).to include('&lt;img src=x onerror=alert(1)&gt;')
        expect(response.body).not_to include('<img src=x onerror=alert(1)>')
        expect(response.body).to include('[overflow-wrap:anywhere]')
        expect(response.body).to include('script_tag')
        expect(response.body).to include('data-controller="clipboard"')
        expect(response.body).to include('req-security-event-xss')
      end
    end

    it 'IP制限状態カードを表示する' do
      admin = create(:user, :admin)
      event = create(:security_event, ip_address: '8.8.8.8', matched_rule: 'fail2ban/scanner_paths')
      create(:security_event, ip_address: '8.8.8.8', matched_rule: 'auth/sign_in/ip')
      sign_in admin

      get admin_security_event_path(event)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('IP制限状態')
        expect(response.body).to include('8.8.8.8')
        expect(response.body).to include('手動制限')
        expect(response.body).to include('自動制限')
        expect(response.body).to include('関連イベント')
        expect(response.body).to include(new_admin_passkey_reauthentication_path)
      end
    end

    it 'fresh reauth済みなら手動制限フォームを表示する' do
      admin = create(:user, :admin)
      event = create(:security_event, ip_address: '8.8.8.8')
      sign_in admin
      stub_fresh_admin_reauthentication

      get admin_security_event_path(event)

      aggregate_failures do
        expect(response.body).to include('このIPを手動制限')
        expect(response.body).to include('確認文字列 BLOCK IP')
        expect(response.body).to include(manual_ip_block_admin_security_event_path(event))
      end
    end
  end

  describe 'PATCH /admin/security_events/:id/resolve' do
    it 'resolvedに更新してAuditLogを残す' do
      admin = create(:user, :admin)
      event = create(:security_event)
      sign_in admin

      patch resolve_admin_security_event_path(event)

      aggregate_failures do
        expect(response).to redirect_to(admin_security_event_path(event))
        expect(event.reload.resolved_at).to be_present
        expect(AuditLog.last).to have_attributes(action: 'admin.security_events.resolved', actor_user_id: admin.id)
      end
    end
  end

  describe 'PATCH /admin/security_events/:id/ignore' do
    it 'ignoredに更新してAuditLogを残す' do
      admin = create(:user, :admin)
      event = create(:security_event)
      sign_in admin

      patch ignore_admin_security_event_path(event)

      aggregate_failures do
        expect(response).to redirect_to(admin_security_event_path(event))
        expect(event.reload.ignored_at).to be_present
        expect(AuditLog.last).to have_attributes(action: 'admin.security_events.ignored', actor_user_id: admin.id)
      end
    end
  end

  describe 'IP access operations' do
    around do |example|
      original_store = Rack::Attack.cache.store
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      Rack::Attack.reset!

      example.run
    ensure
      Rack::Attack.reset!
      Rack::Attack.cache.store = original_store
    end

    it 'fresh reauthなしでは手動IP制限を実行しない' do
      admin = create(:user, :admin)
      event = create(:security_event, ip_address: '8.8.8.8')
      sign_in admin
      allow(SystemOperations).to receive(:execute_ip_access_operation)

      post manual_ip_block_admin_security_event_path(event),
           params: { reason: 'abuse mitigation', confirmation: 'BLOCK IP' }

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_security_event_path(event)))
        expect(SystemOperations).not_to have_received(:execute_ip_access_operation)
      end
    end

    it 'reason blankではSystemOperationsを呼ばない' do
      admin = create(:user, :admin)
      event = create(:security_event, ip_address: '8.8.8.8')
      sign_in admin
      stub_fresh_admin_reauthentication
      allow(SystemOperations).to receive(:execute_ip_access_operation)

      post manual_ip_block_admin_security_event_path(event),
           params: { reason: ' ', confirmation: 'BLOCK IP' }

      aggregate_failures do
        expect(response).to redirect_to(admin_security_event_path(event))
        expect(SystemOperations).not_to have_received(:execute_ip_access_operation)
      end
    end

    it 'confirmation blankではSystemOperationsを呼ばない' do
      admin = create(:user, :admin)
      event = create(:security_event, ip_address: '8.8.8.8')
      sign_in admin
      stub_fresh_admin_reauthentication
      allow(SystemOperations).to receive(:execute_ip_access_operation)

      post manual_ip_block_admin_security_event_path(event),
           params: { reason: 'abuse mitigation', confirmation: ' ' }

      aggregate_failures do
        expect(response).to redirect_to(admin_security_event_path(event))
        expect(SystemOperations).not_to have_received(:execute_ip_access_operation)
      end
    end

    it 'SystemOperations経由で手動IP制限を作成してAuditLogを残す' do
      admin = create(:user, :admin)
      event = create(:security_event, ip_address: '8.8.8.8')
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post manual_ip_block_admin_security_event_path(event),
             params: { reason: 'abuse mitigation', confirmation: 'BLOCK IP', expires_at: 2.hours.from_now.iso8601 }
      end.to change(SecurityIpBlock, :count).by(1)
        .and change(AuditLog.where(action: 'admin.ip_access.manual_block'), :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(admin_security_event_path(event))
        expect(SecurityIpBlock.last).to have_attributes(ip_address: IPAddr.new('8.8.8.8'), status: 'active')
        expect(AuditLog.last).to have_attributes(outcome: 'succeeded', target_uid: 'ip:8.8.8.8')
      end
    end

    it 'SystemOperations経由で手動IP制限をrevoked解除する' do
      admin = create(:user, :admin)
      event = create(:security_event, ip_address: '8.8.8.8')
      block = create(:security_ip_block, ip_address: '8.8.8.8')
      sign_in admin
      stub_fresh_admin_reauthentication

      post manual_ip_unblock_admin_security_event_path(event),
           params: { reason: 'false positive', confirmation: 'UNBLOCK IP' }

      aggregate_failures do
        expect(response).to redirect_to(admin_security_event_path(event))
        expect(block.reload.status).to eq('revoked')
        expect(AuditLog.last).to have_attributes(action: 'admin.ip_access.manual_unblock', outcome: 'succeeded')
      end
    end

    it 'SystemOperations経由でRack::Attack自動banを解除する' do
      admin = create(:user, :admin)
      event = create(:security_event, ip_address: '8.8.8.8')
      Rack::Attack::Fail2Ban.filter('scanner:8.8.8.8', maxretry: 1, findtime: 10.minutes, bantime: 30.minutes) { true }
      sign_in admin
      stub_fresh_admin_reauthentication

      post rack_attack_ban_reset_admin_security_event_path(event),
           params: { reason: 'false positive', confirmation: 'RESET IP BAN', rack_attack_target: 'all' }

      aggregate_failures do
        expect(response).to redirect_to(admin_security_event_path(event))
        expect(Security::RackAttackBanRegistry.banned_states('8.8.8.8').values).to all(be(false))
        expect(AuditLog.last).to have_attributes(action: 'admin.ip_access.rack_attack_ban_reset', outcome: 'succeeded')
      end
    end

    it 'reserved IPの手動制限は失敗auditを残して拒否する' do
      admin = create(:user, :admin)
      event = create(:security_event, ip_address: '203.0.113.10')
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post manual_ip_block_admin_security_event_path(event),
             params: { reason: 'documentation address', confirmation: 'BLOCK IP' }
      end.to change(AuditLog.where(action: 'admin.ip_access.manual_block', outcome: 'failed'), :count).by(1)

      expect(response).to redirect_to(admin_security_event_path(event))
      expect(flash[:alert]).to eq(I18n.t('admin.ip_access_operations.messages.failure.reserved_ip'))
    end
  end

  describe 'admin dashboard' do
    it 'security event countを表示する' do
      admin = create(:user, :admin)
      create(:security_event, severity: 'high')
      create(:security_event, severity: 'medium', resolved_at: Time.current)
      sign_in admin

      get admin_root_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('未対応イベント')
        expect(response.body).to include('high / critical')
        expect(response.body).to include(admin_security_events_path)
      end
    end
  end

  describe 'admin users show' do
    it 'ユーザー別security events小セクションを表示する' do
      admin = create(:user, :admin)
      user = create(:user)
      event = create(:security_event, actor_user: user, event_type: 'idor_attempt', path: '/receipts/other')
      sign_in admin

      get admin_user_path(user)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('最近のセキュリティイベント')
        expect(response.body).to include(event.event_type)
        expect(response.body).to include('/receipts/other')
        expect(response.body).to include(admin_security_event_path(event))
      end
    end
  end
end
