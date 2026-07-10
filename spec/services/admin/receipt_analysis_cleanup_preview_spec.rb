require 'rails_helper'

RSpec.describe Admin::ReceiptAnalysisCleanupPreview do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-05-23 10:00:00')) { example.run }
  end

  describe '.call' do
    it 'stale / retention cleanupをdry_run true固定で呼ぶ' do
      stale_result = {
        dry_run: true,
        cutoff: 6.hours.ago,
        limit: 100,
        stale_count: 1,
        failed_count: 0,
        canceled_count: 0,
        skipped_count: 1,
        records: [ { run_key: 'stale-run' } ],
        errors: []
      }
      retention_result = {
        dry_run: true,
        cutoff: Time.current,
        limit: 1000,
        expired_count: 1,
        deleted_count: 0,
        records: [ { run_key: 'expired-run' } ]
      }
      allow(ReceiptAnalysisRuns).to receive(:cleanup_stale).and_return(stale_result)
      allow(ReceiptAnalysisRuns).to receive(:cleanup_expired).and_return(retention_result)

      result = described_class.call(dry_run: false)

      aggregate_failures do
        expect(ReceiptAnalysisRuns).to have_received(:cleanup_stale).with(
          cutoff: 6.hours.ago,
          limit: 100,
          dry_run: true
        )
        expect(ReceiptAnalysisRuns).to have_received(:cleanup_expired).with(
          cutoff: Time.current,
          limit: 1000,
          dry_run: true
        )
        expect(result.stale).to eq(stale_result)
        expect(result.retention).to eq(retention_result)
      end
    end

    it 'cutoff / limitを安全に正規化する' do
      allow(ReceiptAnalysisRuns).to receive(:cleanup_stale).and_return({ dry_run: true, records: [] })
      allow(ReceiptAnalysisRuns).to receive(:cleanup_expired).and_return({ dry_run: true, records: [] })

      result = described_class.call(
        stale_cutoff: '2026-05-22T08:30',
        stale_limit: '500',
        retention_cutoff: '2026-05-23T09:15',
        retention_limit: '5000'
      )

      aggregate_failures do
        expect(ReceiptAnalysisRuns).to have_received(:cleanup_stale).with(
          cutoff: Time.zone.parse('2026-05-22 08:30'),
          limit: 100,
          dry_run: true
        )
        expect(ReceiptAnalysisRuns).to have_received(:cleanup_expired).with(
          cutoff: Time.zone.parse('2026-05-23 09:15'),
          limit: 1000,
          dry_run: true
        )
        expect(result.params).to include(
          stale_cutoff: Time.zone.parse('2026-05-22 08:30'),
          stale_limit: 100,
          retention_cutoff: Time.zone.parse('2026-05-23 09:15'),
          retention_limit: 1000
        )
      end
    end

    it '不正なcutoff / limitはdefaultへ戻す' do
      allow(ReceiptAnalysisRuns).to receive(:cleanup_stale).and_return({ dry_run: true, records: [] })
      allow(ReceiptAnalysisRuns).to receive(:cleanup_expired).and_return({ dry_run: true, records: [] })

      described_class.call(
        stale_cutoff: 'not-a-time',
        stale_limit: '-1',
        retention_cutoff: 'not-a-time',
        retention_limit: '0'
      )

      aggregate_failures do
        expect(ReceiptAnalysisRuns).to have_received(:cleanup_stale).with(
          cutoff: 6.hours.ago,
          limit: 100,
          dry_run: true
        )
        expect(ReceiptAnalysisRuns).to have_received(:cleanup_expired).with(
          cutoff: Time.current,
          limit: 1000,
          dry_run: true
        )
      end
    end

    it '文字が混在するlimitを別の件数として扱わない' do
      expect {
        described_class.call(stale_limit: '12abc')
      }.to raise_error(Admin::ReceiptAnalysisCleanupPreview::InvalidParameter, 'stale_limit_invalid')
    end
  end
end
