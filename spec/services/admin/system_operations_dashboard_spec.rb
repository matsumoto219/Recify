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
          'contact_requests.retention_cleanup.execute',
          'receipt_analysis_runs.cleanup_stale.execute',
          'receipt_analysis_runs.cleanup_expired.execute',
          'receipt_images.purge.execute',
          'contact_requests.retention_cleanup.dry_run',
          'receipt_analysis_runs.cleanup_stale.dry_run',
          'receipt_analysis_runs.cleanup_expired.dry_run',
          'receipt_images.purge.dry_run',
          'user_sessions.retention_cleanup.dry_run',
          'audit_logs.retention_cleanup.dry_run',
          'admin.passkey_reauthentication.succeeded',
          'admin.passkey_reauthentication.failed'
        )
        expect(result.audit_log_retention_policies).to include(
          hash_including(category: 'user_delete', label: '退会代行ログ', retention: '自動整理の対象外', excluded: true),
          hash_including(category: 'high_risk_admin', retention: '365日'),
          hash_including(category: 'system_dry_run', retention: '30日')
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
          'receipt_image_purge_dry_run',
          'contact_request_retention_cleanup_dry_run',
          'receipt_analysis_run_stale_cleanup_dry_run',
          'receipt_analysis_run_retention_cleanup_dry_run',
          'user_session_retention_cleanup_dry_run',
          'audit_log_retention_cleanup_dry_run'
        )
        expect(result.recurring_tasks).to all(include(dry_run: true))
        expect(result.recurring_tasks).to all(include(:class_name, :queue, :schedule))
      end
    end
  end
end
