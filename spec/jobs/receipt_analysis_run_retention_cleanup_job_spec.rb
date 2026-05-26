require 'rails_helper'

RSpec.describe ReceiptAnalysisRunRetentionCleanupJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-05-23 10:00:00')) { example.run }
  end

  it 'dry_run trueをdefaultにしてReceiptAnalysisRuns親入口を呼ぶ' do
    result = {
      dry_run: true,
      expired_count: 0,
      deleted_count: 0
    }
    allow(ReceiptAnalysisRuns).to receive(:cleanup_expired).and_return(result)
    allow(Rails.logger).to receive(:info)

    expect(described_class.perform_now).to eq(result)

    aggregate_failures do
      expect(ReceiptAnalysisRuns).to have_received(:cleanup_expired).with(
        cutoff: Time.current,
        limit: 1000,
        dry_run: true
      )
      expect(Rails.logger).to have_received(:info).with(include('[ReceiptAnalysisRunRetentionCleanupJob] completed dry_run=true'))
    end
  end

  it '指定した引数で親入口を呼ぶ' do
    cutoff = 1.day.ago
    result = {
      dry_run: false,
      expired_count: 2,
      deleted_count: 2
    }
    allow(ReceiptAnalysisRuns).to receive(:cleanup_expired).and_return(result)

    expect(described_class.perform_now(cutoff: cutoff, limit: 10, dry_run: false)).to eq(result)

    expect(ReceiptAnalysisRuns).to have_received(:cleanup_expired).with(
      cutoff: cutoff,
      limit: 10,
      dry_run: false
    )
  end
end
