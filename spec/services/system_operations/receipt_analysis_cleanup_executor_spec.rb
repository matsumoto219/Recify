require 'rails_helper'

RSpec.describe SystemOperations::ReceiptAnalysisCleanupExecutor do
  include ActiveSupport::Testing::TimeHelpers

  let(:actor) { create(:user, :admin) }
  let(:request) { instance_double(ActionDispatch::Request, request_id: 'request-id', remote_ip: '127.0.0.1', user_agent: 'System Operation Spec') }
  let(:reauthenticated_at) { Time.current }
  let(:reauthentication) do
    {
      method: 'passkey',
      reauthenticated_at: reauthenticated_at,
      credential_id: 'credential-secret',
      public_key: 'public-key-secret',
      challenge: 'challenge-secret'
    }
  end

  around do |example|
    travel_to(Time.zone.parse('2026-05-23 10:00:00')) { example.run }
  end

  describe '.call' do
    it 'stale_cleanupでcleanup_stale dry_run:falseを実行し、success auditを残す' do
      result_payload = stale_result(records: 25.times.map { |i| { run_key: "run-#{i}" } })
      allow(ReceiptAnalysisRuns).to receive(:cleanup_stale).and_return(result_payload)

      result = described_class.call(
        operation: 'stale_cleanup',
        actor: actor,
        reason: 'clear stale active runs',
        cutoff: '2026-05-23T03:00',
        limit: '500',
        request: request,
        reauthentication: reauthentication
      )

      audit_log = AuditLog.last

      aggregate_failures do
        expect(result).to be_success
        expect(ReceiptAnalysisRuns).to have_received(:cleanup_stale).with(
          cutoff: Time.zone.parse('2026-05-23 03:00'),
          limit: 100,
          dry_run: false
        )
        expect(audit_log).to have_attributes(
          actor_user: actor,
          actor_kind: 'admin',
          action: 'receipt_analysis_runs.cleanup_stale.execute',
          outcome: 'succeeded',
          reason: 'clear stale active runs',
          request_id: 'request-id',
          user_agent: 'System Operation Spec'
        )
        expect(audit_log.metadata).to include(
          'dry_run' => false,
          'limit' => 100,
          'stale_count' => 25,
          'failed_count' => 2,
          'canceled_count' => 1,
          'skipped_count' => 0,
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey',
          'reauthenticated_at' => reauthenticated_at.iso8601
        )
        expect(audit_log.metadata.fetch('sample_run_keys').size).to eq(20)
        expect(audit_log.metadata.to_json).not_to include('credential-secret', 'public-key-secret', 'challenge-secret')
      end
    end

    it 'retention_cleanupでcleanup_expired dry_run:falseを実行し、success auditを残す' do
      result_payload = {
        dry_run: false,
        cutoff: Time.current,
        limit: 1000,
        expired_count: 2,
        deleted_count: 2,
        records: [ { run_key: 'expired-1' }, { run_key: 'expired-2' } ]
      }
      allow(ReceiptAnalysisRuns).to receive(:cleanup_expired).and_return(result_payload)

      result = described_class.call(
        operation: 'retention_cleanup',
        actor: actor,
        reason: 'delete expired terminal runs',
        cutoff: Time.current,
        limit: '5000',
        request: request,
        reauthentication: reauthentication
      )

      audit_log = AuditLog.last

      aggregate_failures do
        expect(result).to be_success
        expect(ReceiptAnalysisRuns).to have_received(:cleanup_expired).with(
          cutoff: Time.current,
          limit: 1000,
          dry_run: false
        )
        expect(audit_log.action).to eq('receipt_analysis_runs.cleanup_expired.execute')
        expect(audit_log.metadata).to include(
          'dry_run' => false,
          'limit' => 1000,
          'expired_count' => 2,
          'deleted_count' => 2,
          'sample_run_keys' => %w[expired-1 expired-2]
        )
      end
    end

    it 'reason blankは拒否し、cleanupを実行しない' do
      allow(ReceiptAnalysisRuns).to receive(:cleanup_stale)

      result = described_class.call(
        operation: 'stale_cleanup',
        actor: actor,
        reason: ' ',
        cutoff: Time.current,
        limit: 10,
        request: request,
        reauthentication: reauthentication
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('reason_required')
        expect(ReceiptAnalysisRuns).not_to have_received(:cleanup_stale)
        expect(AuditLog.last).to have_attributes(
          action: 'receipt_analysis_runs.cleanup_stale.execute',
          outcome: 'failed',
          error_code: 'reason_required'
        )
      end
    end

    it 'reauthentication nilは拒否し、credential情報をauditに保存しない' do
      allow(ReceiptAnalysisRuns).to receive(:cleanup_stale)

      result = described_class.call(
        operation: 'stale_cleanup',
        actor: actor,
        reason: 'missing reauth',
        cutoff: Time.current,
        limit: 10,
        request: request,
        reauthentication: nil
      )

      audit_log = AuditLog.last

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('reauthentication_required')
        expect(ReceiptAnalysisRuns).not_to have_received(:cleanup_stale)
        expect(audit_log.metadata).not_to include('reauthenticated' => true)
        expect(audit_log.metadata.to_json).not_to include('credential_id', 'challenge', 'public_key')
      end
    end

    it 'unknown operationは拒否し、cleanupを実行しない' do
      allow(ReceiptAnalysisRuns).to receive(:cleanup_stale)
      allow(ReceiptAnalysisRuns).to receive(:cleanup_expired)

      result = described_class.call(
        operation: 'unknown',
        actor: actor,
        reason: 'unknown',
        cutoff: Time.current,
        limit: 10,
        request: request,
        reauthentication: reauthentication
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('unknown_operation')
        expect(ReceiptAnalysisRuns).not_to have_received(:cleanup_stale)
        expect(ReceiptAnalysisRuns).not_to have_received(:cleanup_expired)
        expect(AuditLog.last.action).to eq('system_operations.receipt_analysis_cleanup.unknown')
      end
    end

    it 'cleanup失敗時にfailed auditを残す' do
      allow(ReceiptAnalysisRuns).to receive(:cleanup_stale).and_raise(StandardError, 'boom')

      result = described_class.call(
        operation: 'stale_cleanup',
        actor: actor,
        reason: 'cleanup failure',
        cutoff: Time.current,
        limit: 10,
        request: request,
        reauthentication: reauthentication
      )

      audit_log = AuditLog.last

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('cleanup_failed')
        expect(audit_log).to have_attributes(
          action: 'receipt_analysis_runs.cleanup_stale.execute',
          outcome: 'failed',
          error_code: 'cleanup_failed'
        )
        expect(audit_log.metadata).to include(
          'dry_run' => false,
          'sample_run_keys' => [],
          'reauthenticated' => true
        )
      end
    end
  end

  def stale_result(records:)
    {
      dry_run: false,
      cutoff: Time.zone.parse('2026-05-23 03:00'),
      limit: 100,
      stale_count: records.size,
      failed_count: 2,
      canceled_count: 1,
      skipped_count: 0,
      records: records,
      errors: []
    }
  end
end
