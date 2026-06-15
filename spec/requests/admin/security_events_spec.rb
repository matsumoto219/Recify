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
        metadata: { 'field' => 'q' }
      )
      sign_in admin

      get admin_security_event_path(event)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('セキュリティイベント詳細')
        expect(response.body).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
        expect(response.body).not_to include('<script>alert(1)</script>')
        expect(response.body).to include('script_tag')
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
