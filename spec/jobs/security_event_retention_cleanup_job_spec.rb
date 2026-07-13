require 'rails_helper'

RSpec.describe SecurityEventRetentionCleanupJob, type: :job do
  describe '#perform' do
    it 'dry_run trueをdefaultにしてSecurityEvents親入口を呼ぶ' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      result = {
        dry_run: true,
        expired_count: 1,
        expired_ip_action_count: 1,
        deleted_count: 0,
        deleted_ip_action_count: 0,
        sample_event_ids: [ 123 ],
        retentions: { 'low' => 30 },
        cutoffs: { 'low' => 30.days.ago.iso8601 }
      }
      allow(SecurityEvents).to receive(:cleanup_retention).and_return(result)
      allow(Rails.logger).to receive(:info)

      expect(described_class.perform_now(now: now, limit: 10)).to eq(result)

      audit_log = AuditLog.last

      aggregate_failures do
        expect(SecurityEvents).to have_received(:cleanup_retention).with(
          dry_run: true,
          now: now,
          limit: 10
        )
        expect(Rails.logger).to have_received(:info).with(include('[SecurityEventRetentionCleanupJob] completed dry_run=true'))
        expect(audit_log).to have_attributes(
          action: 'security_events.retention_cleanup.dry_run',
          outcome: 'succeeded'
        )
        expect(audit_log.metadata).to include(
          'dry_run' => true,
          'expired_count' => 1,
          'expired_ip_action_count' => 1,
          'deleted_count' => 0,
          'deleted_ip_action_count' => 0,
          'sample_event_ids' => [ 123 ]
        )
      end
    end

    it 'execute時はexecute actionでAuditLogに件数だけを残す' do
      event = create(:security_event, payload_excerpt: '<script>alert(1)</script>')
      result = {
        dry_run: false,
        expired_count: 1,
        expired_ip_action_count: 1,
        deleted_count: 1,
        deleted_ip_action_count: 1,
        sample_event_ids: [ event.id ],
        retentions: { 'low' => 30 },
        cutoffs: { 'low' => 30.days.ago.iso8601 }
      }
      allow(SecurityEvents).to receive(:cleanup_retention).and_return(result)

      described_class.perform_now(dry_run: false, limit: 10)

      audit_log = AuditLog.last

      aggregate_failures do
        expect(audit_log.action).to eq('security_events.retention_cleanup.execute')
        expect(audit_log.metadata).to include(
          'dry_run' => false,
          'expired_ip_action_count' => 1,
          'deleted_count' => 1,
          'deleted_ip_action_count' => 1
        )
        expect(audit_log.metadata.to_s).not_to include('<script>')
      end
    end

    it 'partial failureはexecute auditをfailedとして記録する' do
      allow(SecurityEvents).to receive(:cleanup_retention).and_return(
        dry_run: false,
        expired_count: 2,
        deleted_count: 1,
        skipped_count: 0,
        failed_count: 1,
        errors: [ { event_id: 1, error_class: 'StandardError' } ]
      )

      described_class.perform_now(dry_run: false)

      expect(AuditLog.last).to have_attributes(
        action: 'security_events.retention_cleanup.execute',
        outcome: 'failed',
        error_code: 'partial_cleanup_failure'
      )
    end

    it 'success audit失敗時はdeleteをrollbackしてfailed auditだけを残す' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      expired = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      action = create(
        :security_ip_action,
        source_security_event: expired,
        source: 'rack_attack',
        status: 'observed',
        last_seen_at: now - 31.days,
        expires_at: nil
      )
      allow(AuditLogs).to receive(:record_system_action!).and_wrap_original do |original, **attributes|
        raise ActiveRecord::RecordInvalid, AuditLog.new if attributes[:outcome] == 'succeeded'

        original.call(**attributes)
      end

      expect do
        described_class.perform_now(dry_run: false, now: now)
      end.to raise_error(ActiveRecord::RecordInvalid)

      aggregate_failures do
        expect(SecurityEvent.where(id: expired.id)).to exist
        expect(SecurityIpAction.where(id: action.id)).to exist
        expect(AuditLog.last).to have_attributes(outcome: 'failed', error_code: 'cleanup_failed')
      end
    end

    it '失敗時もpayloadを含めずAuditLogへ記録して再raiseする' do
      allow(SecurityEvents).to receive(:cleanup_retention).and_raise(StandardError, 'boom <script>')

      expect {
        described_class.perform_now(dry_run: true, limit: 10)
      }.to raise_error(StandardError)

      audit_log = AuditLog.last

      aggregate_failures do
        expect(audit_log).to have_attributes(
          action: 'security_events.retention_cleanup.dry_run',
          outcome: 'failed',
          error_code: 'cleanup_failed'
        )
        expect(audit_log.metadata).to include('error_class' => 'StandardError')
        expect(audit_log.metadata.to_s).not_to include('boom')
      end
    end
  end
end
