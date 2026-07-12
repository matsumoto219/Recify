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
        retention_days: 1,
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
          'retention_days' => 1,
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
        retention_days: 1,
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

    it '一部失敗をsuccess auditにせずfailed outcomeとして記録する' do
      result = {
        dry_run: false,
        cutoff: Time.current,
        retention_days: 1,
        limit: 5,
        candidate_count: 1,
        purged_count: 0,
        skipped_count: 0,
        failed_count: 1,
        sample_receipt_ids: [ 123 ],
        sample_receipt_public_ids: [ 'rcpt_sample' ]
      }
      allow(Storage).to receive(:purge_receipt_images).and_return(result)

      expect(described_class.perform_now(dry_run: false, limit: 5)).to eq(result)

      expect(AuditLog.order(:id).last).to have_attributes(
        action: 'receipt_images.purge.execute',
        outcome: 'failed',
        error_code: 'partial_purge_failure'
      )
    end

    it 'success audit失敗時はreceipt markerとattachmentをrollbackしてfileを残す' do
      receipt = create(
        :receipt,
        :completed,
        :with_image,
        keep_image: false,
        image_purge_eligible_at: 2.days.ago
      )
      attachment = receipt.image.attachment
      blob = receipt.image.blob
      allow(AuditLogs).to receive(:record_system_action!).and_wrap_original do |original, **attributes|
        raise ActiveRecord::RecordInvalid, AuditLog.new if attributes[:outcome] == 'succeeded'

        original.call(**attributes)
      end

      expect do
        described_class.perform_now(dry_run: false, limit: 5, cutoff: Time.current)
      end.to raise_error(ActiveRecord::RecordInvalid)

      aggregate_failures do
        expect(receipt.reload.image).to be_attached
        expect(receipt.image_purged_at).to be_nil
        expect(ActiveStorage::Attachment).to exist(attachment.id)
        expect(ActiveStorage::Blob).to exist(blob.id)
        expect(blob.service).to exist(blob.key)
        expect(AuditLog.order(:id).last).to have_attributes(outcome: 'failed', error_code: 'purge_failed')
      end
    end
  end
end
