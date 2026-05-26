require 'rails_helper'

RSpec.describe Admin::SystemOperationsDashboard do
  describe '.call' do
    it 'high-risk policy / queues / audit actions / locked operationsを返す' do
      result = described_class.call

      aggregate_failures do
        expect(result.policy_items).to include(
          'パスキーによる再認証が必要',
          '実行理由の入力が必要',
          '監査ログに記録'
        )
        expect(result.queues).to contain_exactly(
          'default',
          'receipt_ocr',
          'receipt_ai',
          'receipt_finalize'
        )
        expect(result.audit_actions).to include(
          'receipt_analysis_runs.cleanup_stale.execute',
          'receipt_analysis_runs.cleanup_expired.execute',
          'receipt_analysis_runs.cleanup_stale.dry_run',
          'receipt_analysis_runs.cleanup_expired.dry_run',
          'user_sessions.retention_cleanup.dry_run',
          'admin.passkey_reauthentication.succeeded',
          'admin.passkey_reauthentication.failed'
        )
        expect(result.locked_future_operations).to include(
          '機能公開設定の変更',
          '処理時間設定の変更',
          'キューの一時停止・再開',
          '外部サービス状態の切り替え'
        )
      end
    end

    it 'config/recurring.yml からdry-run recurring taskだけを返す' do
      result = described_class.call
      recurring_keys = result.recurring_tasks.map { |task| task[:key] }

      aggregate_failures do
        expect(recurring_keys).to include(
          'orphan_blob_cleanup_dry_run',
          'receipt_analysis_run_stale_cleanup_dry_run',
          'receipt_analysis_run_retention_cleanup_dry_run',
          'user_session_retention_cleanup_dry_run'
        )
        expect(result.recurring_tasks).to all(include(dry_run: true))
        expect(result.recurring_tasks).to all(include(:class_name, :queue, :schedule))
      end
    end
  end
end
