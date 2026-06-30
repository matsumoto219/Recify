require 'rails_helper'

RSpec.describe 'Admin IP blocks', type: :request do
  around do |example|
    original_show_exceptions = Rails.application.env_config['action_dispatch.show_exceptions']
    original_show_detailed_exceptions = Rails.application.env_config['action_dispatch.show_detailed_exceptions']
    original_store = Rack::Attack.cache.store

    Rails.application.env_config['action_dispatch.show_exceptions'] = :all
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = false
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.reset!

    example.run
  ensure
    Rack::Attack.reset!
    Rack::Attack.cache.store = original_store
    Rails.application.env_config['action_dispatch.show_exceptions'] = original_show_exceptions
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = original_show_detailed_exceptions
  end

  def comparable_headers
    response.headers.to_h.except('x-request-id', 'x-runtime')
  end

  def stub_fresh_admin_reauthentication
    allow_any_instance_of(Admin::IpBlocksController).to receive(:admin_passkey_reauthenticated?).and_return(true)
    allow_any_instance_of(Admin::IpBlocksController).to receive(:admin_reauthentication_context).and_return(
      method: 'passkey',
      reauthenticated_at: Time.current
    )
  end

  describe 'GET /admin/ip_blocks' do
    it '非ログインユーザーには既存404と同じbody/headerを返す' do
      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      get admin_ip_blocks_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).not_to include('IP制限一覧')
      end
    end

    it '一般ユーザーには既存404と同じbody/headerを返す' do
      user = create(:user)
      sign_in user

      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      sign_in user
      get admin_ip_blocks_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).not_to include('IP制限一覧')
      end
    end

    it 'adminユーザーはindexを閲覧できる' do
      admin = create(:user, :admin)
      source = create(:security_event, ip_address: '8.8.8.8', matched_rule: 'fail2ban/scanner_paths')
      block = create(:security_ip_block, ip_address: '8.8.8.8', source_security_event: source, reason: 'scanner abuse')
      create(:security_event, ip_address: '8.8.8.8', last_seen_at: 1.hour.ago)
      sign_in admin

      get admin_ip_blocks_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('IP制限一覧')
        expect(response.body).to include('8.8.8.8')
        expect(response.body).to include('scanner abuse')
        expect(response.body).to include(admin_ip_block_path(block))
        expect(response.body).to include(admin_security_event_path(source))
        expect(response.body).to include('IP制限')
        expect(response.body).not_to include('translation missing')
      end
    end

    it 'filter paramsをAdmin queryへ渡す' do
      admin = create(:user, :admin)
      sign_in admin
      allow(Admin).to receive(:ip_blocks).and_call_original

      get admin_ip_blocks_path,
          params: {
            status: 'active',
            ip_address: '8.8.8.8',
            created_by_id: '1',
            source_security_event_id: '2',
            expires_before: '2026-06-24T00:00',
            expires_after: '2026-06-23T00:00',
            created_from: '2026-06-22T00:00',
            created_to: '2026-06-23T00:00',
            limit: '10',
            offset: '20'
          }

      expect(Admin).to have_received(:ip_blocks).with(
        status: 'active',
        ip_address: '8.8.8.8',
        created_by_id: '1',
        source_security_event_id: '2',
        expires_before: '2026-06-24T00:00',
        expires_after: '2026-06-23T00:00',
        created_from: '2026-06-22T00:00',
        created_to: '2026-06-23T00:00',
        limit: '10',
        offset: '20'
      )
    end
  end

  describe 'GET /admin/ip_blocks/:id' do
    it '詳細と関連SecurityEventと解除導線を表示する' do
      admin = create(:user, :admin)
      source = create(:security_event, ip_address: '8.8.8.8', matched_rule: 'manual-review')
      block = create(:security_ip_block, ip_address: '8.8.8.8', source_security_event: source, reason: 'scanner abuse')
      create(:security_event, ip_address: '8.8.8.8', event_type: 'xss_attempt', matched_rule: 'script_tag')
      create(:security_ip_action, ip_address: '8.8.8.8', action_type: 'manual_ip_block', source: 'manual_admin', status: 'active', security_ip_block: block, source_security_event: source)
      sign_in admin

      get admin_ip_block_path(block)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('IP制限詳細')
        expect(response.body).to include('8.8.8.8')
        expect(response.body).to include('scanner abuse')
        expect(response.body).to include(admin_security_event_path(source))
        expect(response.body).to include(admin_audit_logs_path(target_uid: 'ip:8.8.8.8'))
        expect(response.body).to include('関連セキュリティイベント')
        expect(response.body).to include('IPアクション履歴')
        expect(response.body).to include('手動IP制限')
        expect(response.body).to include('xss_attempt')
        expect(response.body).to include(new_admin_passkey_reauthentication_path(return_to: admin_ip_block_path(block)))
      end
    end

    it 'fresh reauth済みならactive未期限切れの解除フォームを表示する' do
      admin = create(:user, :admin)
      block = create(:security_ip_block, ip_address: '8.8.8.8')
      sign_in admin
      stub_fresh_admin_reauthentication

      get admin_ip_block_path(block)

      aggregate_failures do
        expect(response.body).to include('手動制限を解除')
        expect(response.body).to include('確認文字列 UNBLOCK IP')
        expect(response.body).to include(unblock_admin_ip_block_path(block))
      end
    end

    it 'expired/revokedには解除フォームを表示しない' do
      admin = create(:user, :admin)
      expired = create(:security_ip_block, ip_address: '8.8.8.8', expires_at: 1.minute.ago)
      revoked = create(:security_ip_block, :revoked, ip_address: '1.1.1.1')
      sign_in admin
      stub_fresh_admin_reauthentication

      get admin_ip_block_path(expired)
      expired_body = response.body
      get admin_ip_block_path(revoked)
      revoked_body = response.body

      aggregate_failures do
        expect(expired_body).to include('解除操作はできません')
        expect(expired_body).not_to include(unblock_admin_ip_block_path(expired))
        expect(revoked_body).to include('解除操作はできません')
        expect(revoked_body).not_to include(unblock_admin_ip_block_path(revoked))
      end
    end
  end

  describe 'POST /admin/ip_blocks/:id/unblock' do
    it 'fresh reauthなしではSystemOperationsを呼ばない' do
      admin = create(:user, :admin)
      block = create(:security_ip_block, ip_address: '8.8.8.8')
      sign_in admin
      allow(SystemOperations).to receive(:execute_ip_access_operation)

      post unblock_admin_ip_block_path(block),
           params: { reason: 'false positive', confirmation: 'UNBLOCK IP' }

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_ip_block_path(block)))
        expect(SystemOperations).not_to have_received(:execute_ip_access_operation)
      end
    end

    it 'reason blankではSystemOperationsを呼ばない' do
      admin = create(:user, :admin)
      block = create(:security_ip_block, ip_address: '8.8.8.8')
      sign_in admin
      stub_fresh_admin_reauthentication
      allow(SystemOperations).to receive(:execute_ip_access_operation)

      post unblock_admin_ip_block_path(block),
           params: { reason: ' ', confirmation: 'UNBLOCK IP' }

      aggregate_failures do
        expect(response).to redirect_to(admin_ip_block_path(block))
        expect(SystemOperations).not_to have_received(:execute_ip_access_operation)
      end
    end

    it 'confirmation blankではSystemOperationsを呼ばない' do
      admin = create(:user, :admin)
      block = create(:security_ip_block, ip_address: '8.8.8.8')
      sign_in admin
      stub_fresh_admin_reauthentication
      allow(SystemOperations).to receive(:execute_ip_access_operation)

      post unblock_admin_ip_block_path(block),
           params: { reason: 'false positive', confirmation: ' ' }

      aggregate_failures do
        expect(response).to redirect_to(admin_ip_block_path(block))
        expect(SystemOperations).not_to have_received(:execute_ip_access_operation)
      end
    end

    it 'SystemOperations経由でrevoked解除してAuditLogを残す' do
      admin = create(:user, :admin)
      source = create(:security_event, ip_address: '8.8.8.8')
      block = create(:security_ip_block, ip_address: '8.8.8.8', source_security_event: source)
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post unblock_admin_ip_block_path(block),
             params: { reason: 'false positive', confirmation: 'UNBLOCK IP' }
      end.to change(AuditLog.where(action: 'admin.ip_access.manual_unblock', outcome: 'succeeded'), :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(admin_ip_block_path(block))
        expect(block.reload).to have_attributes(status: 'revoked', revoked_by: admin, revoked_reason: 'false positive')
        expect(AuditLog.last).to have_attributes(target_uid: 'ip:8.8.8.8', reason: 'false positive')
        expect(AuditLog.last.metadata).to include('reauthenticated' => true, 'source_security_event_id' => source.id)
      end
    end

    it 'expired/revokedは解除実行しない' do
      admin = create(:user, :admin)
      expired = create(:security_ip_block, ip_address: '8.8.8.8', expires_at: 1.minute.ago)
      revoked = create(:security_ip_block, :revoked, ip_address: '1.1.1.1')
      sign_in admin
      stub_fresh_admin_reauthentication
      allow(SystemOperations).to receive(:execute_ip_access_operation)

      post unblock_admin_ip_block_path(expired),
           params: { reason: 'false positive', confirmation: 'UNBLOCK IP' }
      post unblock_admin_ip_block_path(revoked),
           params: { reason: 'false positive', confirmation: 'UNBLOCK IP' }

      aggregate_failures do
        expect(SystemOperations).not_to have_received(:execute_ip_access_operation)
        expect(expired.reload.status).to eq('active')
        expect(revoked.reload.status).to eq('revoked')
      end
    end
  end
end
