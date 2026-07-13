require 'rails_helper'

RSpec.describe AuditLogRetentionCleanupJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-05-27 10:00:00')) { example.run }
  end

  it 'dry_run trueをdefaultにしてAuditLogs親入口を呼ぶ' do
    result = {
      dry_run: true,
      expired_count: 0,
      deleted_count: 0,
      sample_audit_ids: [],
      categories: [ 'system_dry_run' ],
      cutoffs: {}
    }
    allow(AuditLogs).to receive(:cleanup_retention).and_return(result)
    allow(Rails.logger).to receive(:info)

    expect { expect(described_class.perform_now).to eq(result) }
      .to change(AuditLog, :count).by(1)

    audit_log = AuditLog.last

    aggregate_failures do
      expect(AuditLogs).to have_received(:cleanup_retention).with(
        categories: nil,
        now: kind_of(ActiveSupport::TimeWithZone),
        limit: 1000,
        dry_run: true
      )
      expect(Rails.logger).to have_received(:info).with(include('[AuditLogRetentionCleanupJob] completed dry_run=true'))
      expect(audit_log).to have_attributes(
        actor_kind: 'system',
        action: 'audit_logs.retention_cleanup.dry_run',
        outcome: 'succeeded'
      )
      expect(audit_log.metadata).to include(
        'dry_run' => true,
        'limit' => 1000,
        'expired_count' => 0,
        'deleted_count' => 0,
        'sample_audit_ids' => []
      )
    end
  end

  it '指定した引数で親入口を呼ぶ' do
    now = Time.zone.parse('2026-05-27 09:00:00')
    result = {
      dry_run: false,
      expired_count: 2,
      deleted_count: 2,
      sample_audit_ids: [ 1, 2 ],
      categories: [ 'system_dry_run' ],
      cutoffs: {}
    }
    allow(AuditLogs).to receive(:cleanup_retention).and_return(result)

    expect(described_class.perform_now(categories: [ 'system_dry_run' ], now: now, limit: 10, dry_run: false)).to eq(result)

    expect(AuditLogs).to have_received(:cleanup_retention).with(
      categories: [ 'system_dry_run' ],
      now: now,
      limit: 10,
      dry_run: false
    )
    expect(AuditLog.last.action).to eq('audit_logs.retention_cleanup.execute')
  end

  it 'partial failureはexecute auditをfailedとして記録する' do
    allow(AuditLogs).to receive(:cleanup_retention).and_return(
      dry_run: false,
      expired_count: 2,
      deleted_count: 1,
      failed_count: 1,
      errors: [ { audit_id: 1, error_class: 'StandardError' } ],
      categories: [ 'system_dry_run' ],
      cutoffs: {}
    )

    described_class.perform_now(dry_run: false)

    expect(AuditLog.last).to have_attributes(
      action: 'audit_logs.retention_cleanup.execute',
      outcome: 'failed',
      error_code: 'partial_cleanup_failure'
    )
  end

  it 'success audit失敗時はdeleteをrollbackしてfailed auditだけを残す' do
    expired = create(:audit_log, action: 'audit_logs.retention_cleanup.dry_run', created_at: 31.days.ago)
    allow(AuditLogs).to receive(:record_system_action!).and_wrap_original do |original, **attributes|
      raise ActiveRecord::RecordInvalid, AuditLog.new if attributes[:outcome] == 'succeeded'

      original.call(**attributes)
    end

    expect do
      described_class.perform_now(categories: :system_dry_run, dry_run: false)
    end.to raise_error(ActiveRecord::RecordInvalid)

    aggregate_failures do
      expect(AuditLog.where(id: expired.id)).to exist
      expect(AuditLog.last).to have_attributes(outcome: 'failed', error_code: 'cleanup_failed')
    end
  end

  it 'dry_run nilはjob境界でも安全側に正規化する' do
    allow(AuditLogs).to receive(:cleanup_retention).and_return(
      dry_run: true,
      expired_count: 0,
      deleted_count: 0,
      sample_audit_ids: [],
      categories: [],
      cutoffs: {}
    )

    described_class.perform_now(dry_run: nil)

    aggregate_failures do
      expect(AuditLogs).to have_received(:cleanup_retention).with(
        categories: nil,
        now: kind_of(ActiveSupport::TimeWithZone),
        limit: 1000,
        dry_run: true
      )
      expect(AuditLog.last.action).to eq('audit_logs.retention_cleanup.dry_run')
    end
  end

  it 'dry-run結果をsystem auditとして記録しsample_audit_idsを20件に制限する' do
    result = {
      dry_run: true,
      expired_count: 25,
      deleted_count: 0,
      sample_audit_ids: Array.new(25) { |index| index + 1 },
      categories: [ 'system_dry_run' ],
      cutoffs: { 'system_dry_run' => 30.days.ago.iso8601 },
      secret: 'secret-value',
      session: 'session-value',
      token: 'token-value',
      credential_id: 'credential-value',
      raw_response: 'raw-value',
      prompt: 'prompt-value'
    }
    allow(AuditLogs).to receive(:cleanup_retention).and_return(result)

    described_class.perform_now

    audit_log = AuditLog.last
    metadata_json = audit_log.metadata.to_json

    aggregate_failures do
      expect(audit_log).to have_attributes(
        actor_kind: 'system',
        action: 'audit_logs.retention_cleanup.dry_run',
        outcome: 'succeeded'
      )
      expect(audit_log.metadata).to include(
        'dry_run' => true,
        'limit' => 1000,
        'expired_count' => 25,
        'deleted_count' => 0,
        'categories' => [ 'system_dry_run' ]
      )
      expect(audit_log.metadata['sample_audit_ids']).to eq(Array.new(20) { |index| index + 1 })
      expect(metadata_json).not_to include('secret-value')
      expect(metadata_json).not_to include('session-value')
      expect(metadata_json).not_to include('token-value')
      expect(metadata_json).not_to include('credential-value')
      expect(metadata_json).not_to include('raw-value')
      expect(metadata_json).not_to include('prompt-value')
    end
  end

  it 'cleanup失敗時にfailed auditを残して例外を再raiseする' do
    error = StandardError.new('boom')
    allow(AuditLogs).to receive(:cleanup_retention).and_raise(error)

    expect do
      described_class.perform_now
    end.to raise_error(StandardError, 'boom')
      .and change(AuditLog, :count).by(1)

    audit_log = AuditLog.last

    aggregate_failures do
      expect(audit_log).to have_attributes(
        actor_kind: 'system',
        action: 'audit_logs.retention_cleanup.dry_run',
        outcome: 'failed',
        error_code: 'cleanup_failed'
      )
      expect(audit_log.metadata).to include(
        'dry_run' => true,
        'limit' => 1000,
        'error_class' => 'StandardError',
        'sample_audit_ids' => []
      )
      expect(audit_log.metadata).not_to have_key('error_message')
    end
  end
end
