require 'rails_helper'

RSpec.describe Storage::ReceiptImagePurgeJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-06-03 03:50:00')) { example.run }
  end

  describe '#perform' do
    it 'default dry_runでStorage親入口を呼び、dry-run auditを残す' do
      result = {
        dry_run: true,
        cutoff: Time.current,
        limit: 100,
        candidate_count: 1,
        purged_count: 0,
        skipped_count: 1,
        failed_count: 0,
        sample_receipt_ids: [ 123 ],
        sample_receipt_public_ids: [ 'rcpt_sample' ]
      }
      allow(Storage).to receive(:purge_receipt_images).and_return(result)

      job_result = described_class.perform_now
      audit_log = AuditLog.order(:id).last

      aggregate_failures do
        expect(job_result).to eq(result)
        expect(Storage).to have_received(:purge_receipt_images).with(
          dry_run: true,
          limit: described_class::DEFAULT_LIMIT,
          cutoff: Time.zone.parse('2026-06-03 03:50:00')
        )
        expect(audit_log.action).to eq('receipt_images.purge.dry_run')
        expect(audit_log.outcome).to eq('succeeded')
        expect(audit_log.metadata).to include(
          'dry_run' => true,
          'candidate_count' => 1,
          'purged_count' => 0,
          'sample_receipt_ids' => [ 123 ]
        )
      end
    end

    it 'dry_run:falseではexecute auditを残す' do
      result = {
        dry_run: false,
        cutoff: Time.current,
        limit: 5,
        candidate_count: 1,
        purged_count: 1,
        skipped_count: 0,
        failed_count: 0,
        sample_receipt_ids: [ 123 ],
        sample_receipt_public_ids: [ 'rcpt_sample' ]
      }
      allow(Storage).to receive(:purge_receipt_images).and_return(result)

      described_class.perform_now(dry_run: false, limit: 5, cutoff: Time.current)

      audit_log = AuditLog.order(:id).last

      aggregate_failures do
        expect(Storage).to have_received(:purge_receipt_images).with(
          dry_run: false,
          limit: 5,
          cutoff: Time.zone.parse('2026-06-03 03:50:00')
        )
        expect(audit_log.action).to eq('receipt_images.purge.execute')
        expect(audit_log.outcome).to eq('succeeded')
        expect(audit_log.metadata).to include('purged_count' => 1)
      end
    end

    it '失敗時はfailed auditを残して再raiseする' do
      allow(Storage).to receive(:purge_receipt_images).and_raise(StandardError, 'boom')

      expect {
        described_class.perform_now(dry_run: false, limit: 5, cutoff: Time.current)
      }.to raise_error(StandardError, 'boom')

      audit_log = AuditLog.order(:id).last

      aggregate_failures do
        expect(audit_log.action).to eq('receipt_images.purge.execute')
        expect(audit_log.outcome).to eq('failed')
        expect(audit_log.error_code).to eq('purge_failed')
        expect(audit_log.metadata).to include('error_class' => 'StandardError')
      end
    end
  end
end
