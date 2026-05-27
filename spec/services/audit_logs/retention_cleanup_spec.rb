require 'rails_helper'

RSpec.describe AuditLogs::RetentionCleanup do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-05-27 12:00:00')) { example.run }
  end

  def create_log(action:, outcome: 'succeeded', created_at:, metadata: {})
    create(
      :audit_log,
      action: action,
      outcome: outcome,
      created_at: created_at,
      metadata: metadata,
      before_state: { credential_id: 'credential-secret', visible_count: 1 },
      after_state: { token: 'token-secret', deleted: true }
    )
  end

  describe '.call' do
    it 'user_delete監査ログは削除対象外にする' do
      log = create_log(action: 'admin.users.delete', created_at: 3.years.ago)

      result = described_class.call(dry_run: true, now: Time.current)

      aggregate_failures do
        expect(result[:sample_audit_ids]).not_to include(log.id)
        expect(result[:expired_count]).to eq(0)
      end
    end

    it 'system dry-runは30日超で対象にする' do
      old_log = create_log(action: 'receipt_analysis_runs.cleanup_stale.dry_run', created_at: 31.days.ago)
      recent_log = create_log(action: 'receipt_analysis_runs.cleanup_expired.dry_run', created_at: 10.days.ago)

      result = described_class.call(dry_run: true, categories: :system_dry_run, now: Time.current)

      aggregate_failures do
        expect(result[:expired_count]).to eq(1)
        expect(result[:sample_audit_ids]).to contain_exactly(old_log.id)
        expect(result[:sample_audit_ids]).not_to include(recent_log.id)
        expect(AuditLog.where(id: old_log.id)).to exist
      end
    end

    it 'passkey reauthは90日超で対象にする' do
      old_log = create_log(action: 'admin.passkey_reauthentication.succeeded', created_at: 91.days.ago)
      recent_log = create_log(action: 'admin.passkey_reauthentication.failed', created_at: 30.days.ago)

      result = described_class.call(dry_run: true, categories: :passkey_reauth, now: Time.current)

      expect(result[:sample_audit_ids]).to contain_exactly(old_log.id)
      expect(result[:sample_audit_ids]).not_to include(recent_log.id)
    end

    it 'high-risk admin actionは365日以内なら対象外にする' do
      recent_log = create_log(action: 'admin.users.lock', created_at: 364.days.ago)
      old_log = create_log(action: 'admin.users.session_revoke', created_at: 366.days.ago)

      result = described_class.call(dry_run: true, categories: :high_risk_admin, now: Time.current)

      expect(result[:sample_audit_ids]).to contain_exactly(old_log.id)
      expect(result[:sample_audit_ids]).not_to include(recent_log.id)
    end

    it 'cleanup failed auditは180日超で対象にする' do
      failed_log = create_log(action: 'user_sessions.retention_cleanup.dry_run', outcome: 'failed', created_at: 181.days.ago)
      succeeded_log = create_log(action: 'user_sessions.retention_cleanup.dry_run', outcome: 'succeeded', created_at: 181.days.ago)

      result = described_class.call(dry_run: true, categories: :cleanup_failed, now: Time.current)

      expect(result[:sample_audit_ids]).to contain_exactly(failed_log.id)
      expect(result[:sample_audit_ids]).not_to include(succeeded_log.id)
    end

    it 'unknown actionは対象外にする' do
      log = create_log(action: 'unknown.action', created_at: 3.years.ago)

      result = described_class.call(dry_run: true, now: Time.current)

      expect(result[:sample_audit_ids]).not_to include(log.id)
    end

    it 'dry_run:false はeligibleのみ削除する' do
      expired = create_log(action: 'audit_logs.retention_cleanup.dry_run', created_at: 31.days.ago)
      excluded = create_log(action: 'admin.users.delete', created_at: 3.years.ago)

      result = described_class.call(dry_run: false, categories: :system_dry_run, now: Time.current)

      aggregate_failures do
        expect(result[:deleted_count]).to eq(1)
        expect(AuditLog.where(id: expired.id)).not_to exist
        expect(AuditLog.where(id: excluded.id)).to exist
      end
    end

    it 'limitとsample上限を適用する' do
      create_list(:audit_log, 25, action: 'audit_logs.retention_cleanup.dry_run', created_at: 31.days.ago)

      result = described_class.call(dry_run: true, categories: :system_dry_run, now: Time.current, limit: 25)

      aggregate_failures do
        expect(result[:expired_count]).to eq(25)
        expect(result[:sample_audit_ids].size).to eq(20)
      end
    end

    it '戻り値にsecret/session/token/credential/raw/promptを含めない' do
      create_log(
        action: 'audit_logs.retention_cleanup.dry_run',
        created_at: 31.days.ago,
        metadata: {
          secret: 'secret-value',
          session: 'session-value',
          token: 'token-value',
          credential_id: 'credential-value',
          raw_response: 'raw-value',
          prompt: 'prompt-value'
        }
      )

      result = described_class.call(dry_run: true, categories: :system_dry_run, now: Time.current)
      payload = result.to_json

      expect(payload).not_to include(
        'secret-value',
        'session-value',
        'token-value',
        'credential-value',
        'raw-value',
        'prompt-value'
      )
    end
  end
end
