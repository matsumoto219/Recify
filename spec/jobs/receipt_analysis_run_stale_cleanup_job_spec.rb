require 'rails_helper'

RSpec.describe ReceiptAnalysisRunStaleCleanupJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-05-23 10:00:00')) { example.run }
  end

  it 'dry_run trueをdefaultにしてReceiptAnalysisRuns親入口を呼ぶ' do
    result = {
      dry_run: true,
      stale_count: 0,
      failed_count: 0,
      canceled_count: 0,
      skipped_count: 0,
      errors: []
    }
    allow(ReceiptAnalysisRuns).to receive(:cleanup_stale).and_return(result)
    allow(Rails.logger).to receive(:info)

    expect(described_class.perform_now).to eq(result)

    aggregate_failures do
      expect(ReceiptAnalysisRuns).to have_received(:cleanup_stale).with(
        cutoff: 6.hours.ago,
        limit: 100,
        dry_run: true
      )
      expect(Rails.logger).to have_received(:info).with(include('[ReceiptAnalysisRunStaleCleanupJob] completed dry_run=true'))
    end
  end

  it '指定した引数で親入口を呼ぶ' do
    cutoff = 12.hours.ago
    result = {
      dry_run: false,
      stale_count: 2,
      failed_count: 1,
      canceled_count: 1,
      skipped_count: 0,
      errors: []
    }
    allow(ReceiptAnalysisRuns).to receive(:cleanup_stale).and_return(result)

    expect(described_class.perform_now(cutoff: cutoff, limit: 5, dry_run: false)).to eq(result)

    expect(ReceiptAnalysisRuns).to have_received(:cleanup_stale).with(
      cutoff: cutoff,
      limit: 5,
      dry_run: false
    )
  end
end
