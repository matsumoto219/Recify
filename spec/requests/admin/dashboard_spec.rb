require 'rails_helper'

RSpec.describe 'Admin dashboard', type: :request do
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

  describe 'GET /admin' do
    it '非ログインユーザーはログインへリダイレクトする' do
      get admin_root_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it '一般ユーザーには既存404と同じbody/headerを返す' do
      user = create(:user)
      sign_in user

      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      sign_in user
      get admin_root_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).to include(I18n.t('errors.not_found.title'))
        expect(response.body).not_to include('管理トップ')
        expect(response.body).not_to include('解析状況')
      end
    end

    it '既存sessionのadminがguest化された場合は404にする' do
      admin = create(:user, :admin)
      sign_in admin

      admin.update!(guest: true)
      get admin_root_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.body).to include(I18n.t('errors.not_found.title'))
        expect(response.body).not_to include('管理トップ')
        expect(response.body).not_to include('解析状況')
      end
    end

    it '既存sessionのadminがlockedになった場合はadmin画面を表示しない' do
      admin = create(:user, :admin)
      sign_in admin

      admin.lock_access!(send_instructions: false)
      get admin_root_path

      aggregate_failures do
        expect([ 302, 404 ]).to include(response.status)
        expect(response).to redirect_to(new_user_session_path) if response.redirect?
        expect(response.body).not_to include('管理トップ')
        expect(response.body).not_to include('解析状況')
      end
    end

    it '既存sessionのadminがunconfirmedになった場合はadmin画面を表示しない' do
      admin = create(:user, :admin)
      sign_in admin

      admin.update_column(:confirmed_at, nil)
      get admin_root_path

      aggregate_failures do
        expect([ 302, 404 ]).to include(response.status)
        expect(response).to redirect_to(new_user_session_path) if response.redirect?
        expect(response.body).not_to include('管理トップ')
        expect(response.body).not_to include('解析状況')
      end
    end

    it 'adminユーザーは総合トップを閲覧できる' do
      admin = create(:user, :admin)
      create(:passkey, user: admin)
      create(:receipt_analysis_run, :running, updated_at: 7.hours.ago)
      create(:receipt_analysis_run, :failed)
      create(:receipt, :review_needed)
      create(:audit_log, :failed, actor_kind: 'admin')
      create(:contact_request, status: 'open', category: 'security')
      sign_in admin
      allow(SystemOperations).to receive(:execute_receipt_analysis_cleanup)
      allow(Analysis::RetryService).to receive(:call)

      get admin_root_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('管理トップ')
        expect(response.body).to include('解析状況')
        expect(response.body).to include('Cleanup / retention')
        expect(response.body).to include('監査ログ')
        expect(response.body).to include('問い合わせ')
        expect(response.body).to include('セキュリティ / 再認証')
        expect(response.body).to include('システム運用')
        expect(response.body).to include('制限中の操作')
        expect(response.body).to include(admin_receipt_analysis_runs_path)
        expect(response.body).to include(admin_receipt_analysis_cleanup_path)
        expect(response.body).to include(admin_audit_logs_path)
        expect(response.body).to include(admin_contact_requests_path)
        expect(response.body).to include(admin_system_operations_path)
        expect(response.body).to include(new_admin_passkey_reauthentication_path)
        expect(response.body).to include(settings_security_path)
        expect(response.body).to include('default')
        expect(response.body).to include('receipt_ocr')
        expect(response.body).to include('receipt_ai')
        expect(response.body).to include('receipt_finalize')
        expect(response.body).to include('機能公開設定の変更')
        expect(response.body).not_to include('RAW OCR RESPONSE')
        expect(response.body).not_to include('FULL PROMPT')
        expect(response.body).not_to include('RAW AI RESPONSE')
        expect(response.body).not_to include('SECRET')
        expect(response.body).not_to include(admin_receipt_analysis_cleanup_stale_path)
        expect(response.body).not_to include(admin_receipt_analysis_cleanup_retention_path)
        expect(response.body).not_to include('name="reason"')
        expect(response.body).not_to include('Stale cleanupを実行')
        expect(response.body).not_to include('Retention cleanupを実行')
        expect_no_admin_execution
      end
    end

    it 'request開始時のlocaleが英語でもadmin dashboardは日本語固定で、localeを汚染しない' do
      admin = create(:user, :admin)
      sign_in admin
      original_locale = I18n.locale
      I18n.locale = :en

      get admin_root_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('管理トップ')
        expect(response.body).to include('解析状況')
        expect(response.body).not_to include('translation missing')
        expect(I18n.locale).to eq(:en)
      end
    ensure
      I18n.locale = original_locale if defined?(original_locale)
    end

    it 'dashboard#show を/admin rootとして使う' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_root_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('管理運用に必要な状態サマリ')
        expect(response.body).not_to include('Latest runs')
        expect(response.body).not_to include('Filters')
      end
    end
  end
end
