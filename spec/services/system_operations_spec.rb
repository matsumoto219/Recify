require 'rails_helper'

RSpec.describe SystemOperations do
  describe '.execute_receipt_analysis_cleanup' do
    it 'ReceiptAnalysisCleanupExecutorへ委譲する親入口である' do
      allow(SystemOperations::ReceiptAnalysisCleanupExecutor).to receive(:call).and_return(SystemOperations::Result.new(success: true))

      result = described_class.execute_receipt_analysis_cleanup(
        operation: 'stale_cleanup',
        actor: build_stubbed(:user, :admin),
        reason: 'cleanup',
        cutoff: Time.current,
        limit: 10,
        request: nil,
        reauthentication: { method: 'passkey', reauthenticated_at: Time.current }
      )

      aggregate_failures do
        expect(result).to be_success
        expect(SystemOperations::ReceiptAnalysisCleanupExecutor).to have_received(:call).with(
          operation: 'stale_cleanup',
          actor: kind_of(User),
          reason: 'cleanup',
          cutoff: kind_of(ActiveSupport::TimeWithZone),
          limit: 10,
          request: nil,
          reauthentication: hash_including(method: 'passkey')
        )
      end
    end
  end
end
