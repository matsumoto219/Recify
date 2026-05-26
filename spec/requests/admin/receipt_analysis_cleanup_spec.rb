require 'rails_helper'

RSpec.describe 'Admin receipt analysis cleanup preview', type: :request do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    original_show_exceptions = Rails.application.env_config['action_dispatch.show_exceptions']
    original_show_detailed_exceptions = Rails.application.env_config['action_dispatch.show_detailed_exceptions']
    original_adapter = ActiveJob::Base.queue_adapter

    Rails.application.env_config['action_dispatch.show_exceptions'] = :all
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = false
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs

    travel_to(Time.zone.parse('2026-05-23 10:00:00')) { example.run }
  ensure
    clear_enqueued_jobs
    ActiveJob::Base.queue_adapter = original_adapter
    Rails.application.env_config['action_dispatch.show_exceptions'] = original_show_exceptions
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = original_show_detailed_exceptions
  end

  def comparable_headers
    response.headers.to_h.except('x-request-id', 'x-runtime')
  end

  def expect_no_cleanup_or_analysis_jobs
    forbidden_jobs = [
      ReceiptOcrJob,
      ReceiptAiEnrichmentJob,
      ReceiptFinalizeJob,
      ReceiptAnalysisRunStaleCleanupJob,
      ReceiptAnalysisRunRetentionCleanupJob
    ]

    expect(enqueued_jobs.select { |job| forbidden_jobs.include?(job[:job]) }).to be_empty
  end

  describe 'GET /admin/receipt_analysis_cleanup' do
    it '非ログインユーザーはログインへリダイレクトする' do
      get admin_receipt_analysis_cleanup_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it '一般ユーザーには既存404と同じbody/headerを返す' do
      user = create(:user)
      sign_in user

      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      sign_in user
      get admin_receipt_analysis_cleanup_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).to include(I18n.t('errors.not_found.title'))
        expect(response.body).not_to include('Cleanup preview')
      end
    end

    it 'adminユーザーはdry-run previewを閲覧できる' do
      admin = create(:user, :admin)
      stale_run = create_stale_run
      expired_run = create(:receipt_analysis_run, :succeeded, expires_at: 1.day.ago)
      sign_in admin

      get admin_receipt_analysis_cleanup_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('Cleanup preview')
        expect(response.body).to include('解析run管理')
        expect(response.body).to include('監査ログ')
        expect(response.body).to include('Stale active runs dry-run')
        expect(response.body).to include('Expired terminal runs dry-run')
        expect(response.body).to include('stale_count')
        expect(response.body).to include('expired_count')
        expect(response.body).to include(stale_run.run_key)
        expect(response.body).to include(expired_run.run_key)
        expect(response.body).to include(admin_receipt_analysis_run_path(stale_run.run_key))
        expect(response.body).to include(admin_receipt_analysis_run_path(expired_run.run_key))
        expect(response.body).to include('dry_run:false')
      end
    end

    it 'dry_run:false paramsを渡しても実更新/削除しない' do
      admin = create(:user, :admin)
      stale_run = create_stale_run
      expired_run = create(:receipt_analysis_run, :succeeded, expires_at: 1.day.ago)
      sign_in admin

      get admin_receipt_analysis_cleanup_path, params: { dry_run: 'false' }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(stale_run.reload.status).to eq('queued')
        expect(stale_run.receipt.reload.status).to eq('processing')
        expect(ReceiptAnalysisRun.exists?(expired_run.id)).to eq(true)
        expect(response.body).to include('skipped_count')
        expect(response.body).to include('deleted_count')
      end
    end

    it 'GETでcleanup jobや解析jobをenqueueしない' do
      admin = create(:user, :admin)
      sign_in admin
      allow(ReceiptAnalysisRunStaleCleanupJob).to receive(:perform_later)
      allow(ReceiptAnalysisRunRetentionCleanupJob).to receive(:perform_later)
      allow(ReceiptAnalysisRunStaleCleanupJob).to receive(:perform_now)
      allow(ReceiptAnalysisRunRetentionCleanupJob).to receive(:perform_now)

      get admin_receipt_analysis_cleanup_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect_no_cleanup_or_analysis_jobs
        expect(ReceiptAnalysisRunStaleCleanupJob).not_to have_received(:perform_later)
        expect(ReceiptAnalysisRunRetentionCleanupJob).not_to have_received(:perform_later)
        expect(ReceiptAnalysisRunStaleCleanupJob).not_to have_received(:perform_now)
        expect(ReceiptAnalysisRunRetentionCleanupJob).not_to have_received(:perform_now)
      end
    end

    it 'raw/prompt/secret系を表示しない' do
      admin = create(:user, :admin)
      run = create_stale_run
      run.update_columns(
        ocr_summary: { raw_response: 'RAW OCR RESPONSE', line_count: 3 },
        ai_input_snapshot: { prompt: 'FULL PROMPT', filtered_content: 'safe' },
        ai_result_summary: { response_body: 'RAW AI RESPONSE' },
        metadata: { secret_token: 'SECRET' },
        updated_at: 7.hours.ago
      )
      sign_in admin

      get admin_receipt_analysis_cleanup_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(run.run_key)
        expect(response.body).not_to include('RAW OCR RESPONSE')
        expect(response.body).not_to include('FULL PROMPT')
        expect(response.body).not_to include('RAW AI RESPONSE')
        expect(response.body).not_to include('SECRET')
      end
    end

    it 'paramsをAdmin facadeへ渡す' do
      admin = create(:user, :admin)
      sign_in admin
      allow(Admin).to receive(:receipt_analysis_cleanup_preview).and_call_original

      get admin_receipt_analysis_cleanup_path,
          params: {
            stale_cutoff: '2026-05-22T08:30',
            stale_limit: '5',
            retention_cutoff: '2026-05-23T09:15',
            retention_limit: '10',
            dry_run: 'false'
          }

      expect(Admin).to have_received(:receipt_analysis_cleanup_preview).with(
        stale_cutoff: '2026-05-22T08:30',
        stale_limit: '5',
        retention_cutoff: '2026-05-23T09:15',
        retention_limit: '10'
      )
    end
  end

  def create_stale_run
    receipt = create(:receipt, :with_image, :processing)
    run = create(:receipt_analysis_run, receipt: receipt, status: 'queued', stage: 'queued')
    run.update_columns(updated_at: 7.hours.ago)
    run
  end
end
