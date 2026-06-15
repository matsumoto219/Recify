require 'rails_helper'

RSpec.describe SecurityEventRetentionCleanupJob, type: :job do
  describe '#perform' do
    it 'dry_run trueをdefaultにしてSecurityEvents親入口を呼ぶ' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      result = {
        dry_run: true,
        expired_count: 1,
        deleted_count: 0,
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
          'deleted_count' => 0,
          'sample_event_ids' => [ 123 ]
        )
      end
    end

    it 'execute時はexecute actionでAuditLogに件数だけを残す' do
      event = create(:security_event, payload_excerpt: '<script>alert(1)</script>')
      result = {
        dry_run: false,
        expired_count: 1,
        deleted_count: 1,
        sample_event_ids: [ event.id ],
        retentions: { 'low' => 30 },
        cutoffs: { 'low' => 30.days.ago.iso8601 }
      }
      allow(SecurityEvents).to receive(:cleanup_retention).and_return(result)

      described_class.perform_now(dry_run: false, limit: 10)

      audit_log = AuditLog.last

      aggregate_failures do
        expect(audit_log.action).to eq('security_events.retention_cleanup.execute')
        expect(audit_log.metadata).to include('dry_run' => false, 'deleted_count' => 1)
        expect(audit_log.metadata.to_s).not_to include('<script>')
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
