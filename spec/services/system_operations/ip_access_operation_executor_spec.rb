# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SystemOperations::IpAccessOperationExecutor do
  include ActiveSupport::Testing::TimeHelpers

  let(:actor) { create(:user, :admin) }
  let(:request) { instance_double(ActionDispatch::Request, request_id: 'request-id', remote_ip: '192.0.2.50', user_agent: 'IP Access Spec') }
  let(:reauthenticated_at) { Time.current }
  let(:reauthentication) do
    {
      method: 'passkey',
      reauthenticated_at: reauthenticated_at,
      credential_id: 'credential-secret',
      challenge: 'challenge-secret'
    }
  end
  let(:security_event) { create(:security_event, ip_address: '8.8.8.8') }

  around do |example|
    original_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.reset!

    travel_to(Time.zone.parse('2026-06-23 10:00:00')) { example.run }
  ensure
    Rack::Attack.reset!
    Rack::Attack.cache.store = original_store
  end

  it 'manual_ip_blockを実行してAuditLogを保存する' do
    result = described_class.call(
      operation: 'manual_ip_block',
      ip_address: '8.8.8.8',
      actor: actor,
      reason: 'abuse mitigation',
      request: request,
      reauthentication: reauthentication,
      confirmation: 'BLOCK IP',
      source_security_event: security_event,
      expires_at: 2.hours.from_now.iso8601
    )

    audit_log = AuditLog.last

    aggregate_failures do
      expect(result).to be_success
      expect(result.security_ip_block).to have_attributes(ip_address: IPAddr.new('8.8.8.8'), status: 'active')
      expect(audit_log).to have_attributes(
        actor_user: actor,
        action: 'admin.ip_access.manual_block',
        outcome: 'succeeded',
        target_type: 'SecurityIpBlock',
        target_id: result.security_ip_block.id,
        target_uid: 'ip:8.8.8.8',
        reason: 'abuse mitigation',
        request_id: 'request-id',
        user_agent: 'IP Access Spec'
      )
      expect(audit_log.metadata).to include(
        'operation' => 'manual_ip_block',
        'ip_address' => '8.8.8.8',
        'reauthenticated' => true,
        'reauthentication_method' => 'passkey',
        'source_security_event_id' => security_event.id
      )
      expect(audit_log.attributes.to_json).not_to include('credential-secret', 'challenge-secret')
      expect(SecurityIpAction.last).to have_attributes(
        action_type: 'manual_ip_block',
        source: 'manual_admin',
        status: 'active',
        security_ip_block: result.security_ip_block,
        actor_user: actor
      )
    end
  end

  it 'manual_ip_unblockを実行してAuditLogを保存する' do
    block = create(:security_ip_block, ip_address: '8.8.8.8')

    result = described_class.call(
      operation: 'manual_ip_unblock',
      ip_address: '8.8.8.8',
      actor: actor,
      reason: 'false positive',
      request: request,
      reauthentication: reauthentication,
      confirmation: 'UNBLOCK IP',
      source_security_event: security_event
    )

    aggregate_failures do
      expect(result).to be_success
      expect(block.reload.status).to eq('revoked')
      expect(AuditLog.last).to have_attributes(
        action: 'admin.ip_access.manual_unblock',
        outcome: 'succeeded',
        target_type: 'SecurityIpBlock',
        target_id: block.id,
        target_uid: 'ip:8.8.8.8'
      )
      expect(SecurityIpAction.last).to have_attributes(
        action_type: 'manual_ip_unblock',
        source: 'manual_admin',
        status: 'revoked',
        security_ip_block: block,
        actor_user: actor
      )
    end
  end

  it 'manual_ip_blockのsuccess audit失敗時はblockをrollbackする' do
    allow(AuditLogs).to receive(:record_admin_action!).and_wrap_original do |original, **attributes|
      raise ActiveRecord::RecordInvalid, AuditLog.new if attributes[:outcome] == 'succeeded'

      original.call(**attributes)
    end

    result = described_class.call(
      operation: 'manual_ip_block',
      ip_address: '8.8.8.8',
      actor: actor,
      reason: 'audit failure rollback',
      request: request,
      reauthentication: reauthentication,
      confirmation: 'BLOCK IP',
      source_security_event: security_event
    )

    aggregate_failures do
      expect(result).to be_failure
      expect(SecurityIpBlock.currently_effective_for_ip('8.8.8.8')).to be_empty
      expect(Security.ip_blocked?('8.8.8.8')).to be(false)
      expect(SecurityIpAction.where(ip_address: '8.8.8.8')).to be_empty
      expect(AuditLog.last).to have_attributes(action: 'admin.ip_access.manual_block', outcome: 'failed')
    end
  end

  it 'manual_ip_unblockのsuccess audit失敗時は解除をrollbackする' do
    block = create(:security_ip_block, ip_address: '8.8.8.8')
    allow(AuditLogs).to receive(:record_admin_action!).and_wrap_original do |original, **attributes|
      raise ActiveRecord::RecordInvalid, AuditLog.new if attributes[:outcome] == 'succeeded'

      original.call(**attributes)
    end

    result = described_class.call(
      operation: 'manual_ip_unblock',
      ip_address: '8.8.8.8',
      actor: actor,
      reason: 'audit failure rollback',
      request: request,
      reauthentication: reauthentication,
      confirmation: 'UNBLOCK IP',
      source_security_event: security_event
    )

    aggregate_failures do
      expect(result).to be_failure
      expect(block.reload.status).to eq('active')
      expect(Security.ip_blocked?('8.8.8.8')).to be(true)
      expect(SecurityIpAction.where(ip_address: '8.8.8.8')).to be_empty
      expect(AuditLog.last).to have_attributes(action: 'admin.ip_access.manual_unblock', outcome: 'failed')
    end
  end

  it 'rack_attack_ip_ban_resetを実行してAuditLogを保存する' do
    Rack::Attack::Fail2Ban.filter('scanner:8.8.8.8', maxretry: 1, findtime: 10.minutes, bantime: 30.minutes) { true }

    result = described_class.call(
      operation: 'rack_attack_ip_ban_reset',
      ip_address: '8.8.8.8',
      actor: actor,
      reason: 'false positive',
      request: request,
      reauthentication: reauthentication,
      confirmation: 'RESET IP BAN',
      source_security_event: security_event,
      rack_attack_target: 'all'
    )

    aggregate_failures do
      expect(result).to be_success
      expect(Security::RackAttackBanRegistry.banned_states('8.8.8.8').values).to all(be(false))
      expect(AuditLog.last).to have_attributes(
        action: 'admin.ip_access.rack_attack_ban_reset',
        outcome: 'succeeded',
        target_uid: 'ip:8.8.8.8'
      )
      expect(AuditLog.last.metadata).to include('reset_targets' => [ 'scanner', 'admin_probe', 'direct_upload_probe' ])
      expect(SecurityIpAction.last).to have_attributes(
        action_type: 'rack_attack_ban_reset',
        source: 'manual_admin',
        status: 'reset',
        actor_user: actor
      )
    end
  end

  it 'Rack::Attack resetのintent audit失敗時はbanを解除しない' do
    Rack::Attack::Fail2Ban.filter('scanner:8.8.8.8', maxretry: 1, findtime: 10.minutes, bantime: 30.minutes) { true }
    allow(AuditLogs).to receive(:record_admin_action!).and_wrap_original do |original, **attributes|
      if attributes[:action] == 'admin.ip_access.rack_attack_ban_reset_requested'
        raise ActiveRecord::RecordInvalid, AuditLog.new
      end

      original.call(**attributes)
    end

    result = described_class.call(
      operation: 'rack_attack_ip_ban_reset',
      ip_address: '8.8.8.8',
      actor: actor,
      reason: 'intent audit failure',
      request: request,
      reauthentication: reauthentication,
      confirmation: 'RESET IP BAN',
      source_security_event: security_event,
      rack_attack_target: 'all'
    )

    aggregate_failures do
      expect(result).to be_failure
      expect(Security::RackAttackBanRegistry.banned_states('8.8.8.8').fetch('scanner')).to be(true)
      expect(SecurityIpAction.where(ip_address: '8.8.8.8')).to be_empty
      expect(AuditLog.last).to have_attributes(action: 'admin.ip_access.rack_attack_ban_reset', outcome: 'failed')
    end
  end

  it 'Rack::Attack resetのoutcome audit失敗時もintentを残して適用済みとして返す' do
    Rack::Attack::Fail2Ban.filter('scanner:8.8.8.8', maxretry: 1, findtime: 10.minutes, bantime: 30.minutes) { true }
    allow(AuditLogs).to receive(:record_admin_action!).and_wrap_original do |original, **attributes|
      if attributes[:action] == 'admin.ip_access.rack_attack_ban_reset' && attributes[:outcome] == 'succeeded'
        raise ActiveRecord::RecordInvalid, AuditLog.new
      end

      original.call(**attributes)
    end

    result = described_class.call(
      operation: 'rack_attack_ip_ban_reset',
      ip_address: '8.8.8.8',
      actor: actor,
      reason: 'outcome audit failure',
      request: request,
      reauthentication: reauthentication,
      confirmation: 'RESET IP BAN',
      source_security_event: security_event,
      rack_attack_target: 'all'
    )

    aggregate_failures do
      expect(result).to be_success
      expect(Security::RackAttackBanRegistry.banned_states('8.8.8.8').values).to all(be(false))
      expect(AuditLog.where(action: 'admin.ip_access.rack_attack_ban_reset_requested', outcome: 'succeeded')).to exist
      expect(AuditLog.where(action: 'admin.ip_access.rack_attack_ban_reset', outcome: 'failed')).to exist
      expect(SecurityIpAction.last).to have_attributes(action_type: 'rack_attack_ban_reset', status: 'reset')
    end
  end

  it 'fresh passkey reauthentication必須' do
    result = described_class.call(
      operation: 'manual_ip_block',
      ip_address: '8.8.8.8',
      actor: actor,
      reason: 'abuse mitigation',
      request: request,
      reauthentication: {},
      confirmation: 'BLOCK IP',
      source_security_event: security_event
    )

    aggregate_failures do
      expect(result).to be_failure
      expect(result.error_code).to eq('reauthentication_required')
      expect(AuditLog.last).to have_attributes(action: 'admin.ip_access.manual_block', outcome: 'failed')
    end
  end

  it 'confirmation phrase必須' do
    result = described_class.call(
      operation: 'manual_ip_block',
      ip_address: '8.8.8.8',
      actor: actor,
      reason: 'abuse mitigation',
      request: request,
      reauthentication: reauthentication,
      confirmation: 'WRONG',
      source_security_event: security_event
    )

    expect(result).to have_attributes(success: false, error_code: 'confirmation_required')
  end

  it '現在の管理者アクセス元IPは手動制限しない' do
    same_ip_request = instance_double(ActionDispatch::Request, request_id: 'request-id', remote_ip: '8.8.8.8', user_agent: 'IP Access Spec')

    result = described_class.call(
      operation: 'manual_ip_block',
      ip_address: '8.8.8.8',
      actor: actor,
      reason: 'abuse mitigation',
      request: same_ip_request,
      reauthentication: reauthentication,
      confirmation: 'BLOCK IP',
      source_security_event: security_event
    )

    expect(result).to have_attributes(success: false, error_code: 'current_ip_block_forbidden')
  end
end
