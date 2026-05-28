require 'rails_helper'

RSpec.describe Admin::Dashboard do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-05-26 12:00:00')) { example.run }
  end

  describe '.call' do
    it 'admin総合トップ用の軽量summaryを返す' do
      admin = create(:user, :admin)
      external_services_snapshot = {
        ocr: { state: 'down' },
        ai: { state: 'ok' },
        upload: { allowed: false },
        notices: { ocr_down: true }
      }
      storage_snapshot = {
        total_blob_count: 3,
        attached_blob_count: 2,
        orphan_blob_count: 1,
        total_blob_bytes: 24.kilobytes,
        attached_blob_bytes: 20.kilobytes,
        orphan_blob_bytes: 4.kilobytes,
        user_count: 2,
        quota_total_bytes: 3.gigabytes,
        quota_used_bytes: 20.kilobytes
      }
      allow(ExternalServices).to receive(:status_snapshot).and_return(external_services_snapshot)
      allow(Storage).to receive(:system_usage_snapshot).and_return(storage_snapshot)
      create(:passkey, user: admin)
      active_run = create(:receipt_analysis_run, :running, updated_at: 7.hours.ago)
      failed_run = create(:receipt_analysis_run, :failed, created_at: 1.hour.ago)
      review_receipt = create(:receipt, :review_needed)
      review_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: review_receipt,
        final_result_summary: { receipt_status: 'review_needed' }
      )
      expired_run = create(:receipt_analysis_run, :succeeded, expires_at: 1.day.ago)
      create(:audit_log, :failed, actor_kind: 'admin', action: 'admin.passkey_reauthentication.failed', created_at: 30.minutes.ago)
      create(:audit_log, action: 'receipt_analysis.ai_retry', actor_kind: 'admin', created_at: 20.minutes.ago)
      create(:audit_log, action: 'receipt_analysis_runs.cleanup_stale.execute', actor_kind: 'admin', created_at: 10.minutes.ago)
      create(:audit_log, :failed, actor_kind: 'system', created_at: 5.minutes.ago)
      create(:contact_request, status: 'open', category: 'security', created_at: 15.minutes.ago)
      create(:contact_request, status: 'in_progress', category: 'account', created_at: 10.minutes.ago)
      create(:contact_request, status: 'closed', category: 'security', created_at: 5.minutes.ago)

      result = described_class.call(admin_user: admin)

      aggregate_failures do
        expect(result.receipt_analysis).to include(
          active_runs_count: 1,
          failed_runs_count: 1,
          review_needed_receipts_count: 1,
          needs_attention_count: 2,
          latest_run_at: [ active_run, failed_run, review_run, expired_run ].map(&:created_at).max
        )
        expect(result.cleanup).to include(
          stale_dry_run_count: 1,
          expired_dry_run_count: 1
        )
        expect(result.audit).to include(
          recent_failed_admin_actions_count: 1,
          recent_retry_actions_count: 1,
          recent_cleanup_execute_count: 1
        )
        expect(result.contact_requests).to include(
          unresolved_count: 2,
          open_count: 1,
          in_progress_count: 1,
          security_open_count: 1
        )
        expect(result.security).to include(admin_passkey_count: 1)
        expect(result.external_services).to eq(external_services_snapshot)
        expect(result.storage).to eq(storage_snapshot)
        expect(result.system_operations[:queues]).to contain_exactly(
          'default',
          'receipt_ocr',
          'receipt_ai',
          'receipt_finalize'
        )
        expect(result.system_operations[:recurring_dry_run_count]).to be >= 1
        expect(result.locked_future_operations).to include(
          '機能公開設定の変更',
          '処理時間設定の変更',
          'キューの一時停止・再開',
          '外部サービス状態の切り替え',
          'システム設定の変更'
        )
      end
    end

    it 'raw / prompt / secret 系のpayloadをsummaryに含めない' do
      admin = create(:user, :admin)
      run = create(
        :receipt_analysis_run,
        :running,
        updated_at: 7.hours.ago,
        ocr_summary: { raw_response: 'RAW OCR RESPONSE' },
        ai_input_snapshot: { prompt: 'FULL PROMPT' },
        ai_result_summary: { response_body: 'RAW AI RESPONSE' },
        metadata: { secret_token: 'SECRET' }
      )
      create(
        :audit_log,
        metadata: {
          raw_text: 'RAW OCR',
          prompt: 'FULL PROMPT',
          secret_token: 'SECRET',
          run_key: run.run_key
        }
      )

      json = JSON.generate(described_class.call(admin_user: admin).to_h)

      aggregate_failures do
        expect(json).to include('receipt_ocr', '機能公開設定の変更')
        expect(json).not_to include('RAW OCR RESPONSE')
        expect(json).not_to include('FULL PROMPT')
        expect(json).not_to include('RAW AI RESPONSE')
        expect(json).not_to include('SECRET')
      end
    end
  end
end
