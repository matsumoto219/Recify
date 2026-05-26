require 'rails_helper'

RSpec.describe 'Admin system operations', type: :request do
  include ActiveJob::TestHelper

  around do |example|
    original_show_exceptions = Rails.application.env_config['action_dispatch.show_exceptions']
    original_show_detailed_exceptions = Rails.application.env_config['action_dispatch.show_detailed_exceptions']
    original_adapter = ActiveJob::Base.queue_adapter

    Rails.application.env_config['action_dispatch.show_exceptions'] = :all
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = false
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs

    example.run
  ensure
    clear_enqueued_jobs
    ActiveJob::Base.queue_adapter = original_adapter
    Rails.application.env_config['action_dispatch.show_exceptions'] = original_show_exceptions
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = original_show_detailed_exceptions
  end

  def comparable_headers
    response.headers.to_h.except('x-request-id', 'x-runtime')
  end

  def expect_no_admin_execution
    forbidden_jobs = [
      ReceiptOcrJob,
      ReceiptAiEnrichmentJob,
      ReceiptFinalizeJob,
      ReceiptAnalysisRunStaleCleanupJob,
      ReceiptAnalysisRunRetentionCleanupJob
    ]

    expect(enqueued_jobs.select { |job| forbidden_jobs.include?(job[:job]) }).to be_empty
    expect(SystemOperations).not_to have_received(:execute_receipt_analysis_cleanup)
    expect(Analysis::RetryService).not_to have_received(:call)
  end

  describe 'GET /admin/system_operations' do
    it '非ログインユーザーはログインへリダイレクトする' do
      get admin_system_operations_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it '一般ユーザーには既存404と同じbody/headerを返す' do
      user = create(:user)
      sign_in user

      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      sign_in user
      get admin_system_operations_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).to include(I18n.t('errors.not_found.title'))
        expect(response.body).not_to include('システム運用')
      end
    end

    it 'adminユーザーはシステム運用画面を閲覧できる' do
      admin = create(:user, :admin)
      sign_in admin
      allow(SystemOperations).to receive(:execute_receipt_analysis_cleanup)
      allow(Analysis::RetryService).to receive(:call)

      get admin_system_operations_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('システム運用')
        expect(response.body).to include('解析run管理')
        expect(response.body).to include('監査ログ')
        expect(response.body).to include('Cleanup確認')
        expect(response.body).to include(admin_receipt_analysis_runs_path)
        expect(response.body).to include(admin_receipt_analysis_cleanup_path)
        expect(response.body).to include(admin_audit_logs_path)
        expect(response.body).to include('default')
        expect(response.body).to include('receipt_ocr')
        expect(response.body).to include('receipt_ai')
        expect(response.body).to include('receipt_finalize')
        expect(response.body).to include('receipt_analysis_run_stale_cleanup_dry_run')
        expect(response.body).to include('receipt_analysis_run_retention_cleanup_dry_run')
        expect(response.body).to include('orphan_blob_cleanup_dry_run')
        expect(response.body).to include('機能公開設定の変更')
        expect(response.body).to include('処理時間設定の変更')
        expect(response.body).to include('キューの一時停止・再開')
        expect(response.body).to include('外部サービス状態の切り替え')
        expect(response.body).not_to include('RAW OCR RESPONSE')
        expect(response.body).not_to include('FULL PROMPT')
        expect(response.body).not_to include('RAW AI RESPONSE')
        expect(response.body).not_to include('SECRET')
        expect(response.body).not_to include(admin_receipt_analysis_cleanup_stale_path)
        expect(response.body).not_to include(admin_receipt_analysis_cleanup_retention_path)
        expect(response.body).not_to include('name="reason"')
        expect_no_admin_execution
      end
    end
  end
end
