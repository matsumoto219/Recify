require 'rails_helper'

RSpec.describe UserSessionRetentionCleanupJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-05-27 10:00:00')) { example.run }
  end

  it 'dry_run trueをdefaultにしてUserSessions親入口を呼ぶ' do
    result = {
      dry_run: true,
      expired_count: 0,
      deleted_count: 0,
      sample_session_ids: []
    }
    allow(UserSessions).to receive(:cleanup_retention).and_return(result)
    allow(Rails.logger).to receive(:info)

    expect { expect(described_class.perform_now).to eq(result) }
      .to change(AuditLog, :count).by(1)

    audit_log = AuditLog.last

    aggregate_failures do
      expect(UserSessions).to have_received(:cleanup_retention).with(
        cutoff: 90.days.ago,
        limit: 1000,
        dry_run: true
      )
      expect(Rails.logger).to have_received(:info).with(include('[UserSessionRetentionCleanupJob] completed dry_run=true'))
      expect(audit_log).to have_attributes(
        actor_kind: 'system',
        action: 'user_sessions.retention_cleanup.dry_run',
        outcome: 'succeeded'
      )
      expect(audit_log.metadata).to include(
        'dry_run' => true,
        'limit' => 1000,
        'expired_count' => 0,
        'deleted_count' => 0,
        'sample_session_ids' => []
      )
    end
  end

  it '指定した引数で親入口を呼ぶ' do
    cutoff = 120.days.ago
    result = {
      dry_run: false,
      expired_count: 2,
      deleted_count: 2,
      sample_session_ids: [ 1, 2 ]
    }
    allow(UserSessions).to receive(:cleanup_retention).and_return(result)

    expect(described_class.perform_now(cutoff: cutoff, limit: 10, dry_run: false)).to eq(result)

    expect(UserSessions).to have_received(:cleanup_retention).with(
      cutoff: cutoff,
      limit: 10,
      dry_run: false
    )
  end

  it 'dry-run結果をsystem auditとして記録しsample_session_idsを20件に制限する' do
    result = {
      dry_run: true,
      cutoff: Time.current,
      limit: 1000,
      expired_count: 25,
      deleted_count: 0,
      sample_session_ids: Array.new(25) { |index| index + 1 },
      session_uid_digest: 'digest-secret',
      ip_address: '203.0.113.99',
      user_agent: 'Sensitive Browser',
      cookie: 'cookie-secret',
      token: 'token-secret'
    }
    allow(UserSessions).to receive(:cleanup_retention).and_return(result)

    described_class.perform_now

    audit_log = AuditLog.last
    metadata_json = audit_log.metadata.to_json

    aggregate_failures do
      expect(audit_log).to have_attributes(
        actor_kind: 'system',
        action: 'user_sessions.retention_cleanup.dry_run',
        outcome: 'succeeded'
      )
      expect(audit_log.metadata).to include(
        'dry_run' => true,
        'cutoff' => Time.current.iso8601,
        'limit' => 1000,
        'expired_count' => 25,
        'deleted_count' => 0
      )
      expect(audit_log.metadata['sample_session_ids']).to eq(Array.new(20) { |index| index + 1 })
      expect(metadata_json).not_to include('digest-secret')
      expect(metadata_json).not_to include('203.0.113.99')
      expect(metadata_json).not_to include('Sensitive Browser')
      expect(metadata_json).not_to include('cookie-secret')
      expect(metadata_json).not_to include('token-secret')
    end
  end

  it 'cleanup失敗時にfailed auditを残して例外を再raiseする' do
    error = StandardError.new('boom')
    allow(UserSessions).to receive(:cleanup_retention).and_raise(error)

    expect do
      described_class.perform_now
    end.to raise_error(StandardError, 'boom')
      .and change(AuditLog, :count).by(1)

    audit_log = AuditLog.last

    aggregate_failures do
      expect(audit_log).to have_attributes(
        actor_kind: 'system',
        action: 'user_sessions.retention_cleanup.dry_run',
        outcome: 'failed',
        error_code: 'cleanup_failed'
      )
      expect(audit_log.metadata).to include(
        'dry_run' => true,
        'limit' => 1000,
        'error_class' => 'StandardError',
        'sample_session_ids' => []
      )
      expect(audit_log.metadata).not_to have_key('error_message')
    end
  end
end
