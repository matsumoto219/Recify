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
    expect(Analysis).not_to have_received(:retry_receipt_analysis)
  end

  describe 'GET /admin' do
    it '非ログインユーザーには既存404と同じbody/headerを返す' do
      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      get admin_root_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.location).to be_nil
        expect(response.body).to include(I18n.t('errors.not_found.title'))
        expect(response.body).not_to include(new_user_session_path)
        expect(response.body).not_to include('admin')
        expect(response.body).not_to include('管理者')
        expect(response.body).not_to include('forbidden')
        expect(response.body).not_to include('管理トップ')
        expect(response.body).not_to include('解析状況')
      end
    end

    it '非ログインユーザーのadmin配下既存routeと未定義routeは通常404と判別しづらい' do
      paths = [
        admin_root_path,
        admin_users_path,
        admin_receipt_analysis_runs_path,
        admin_system_settings_path,
        admin_contact_requests_path,
        admin_external_services_status_path,
        '/admin/anything'
      ]

      get '/no_such_page'
      expected_body = response.body
      expected_headers = comparable_headers

      paths.each do |path|
        get path

        aggregate_failures path do
          expect(response).to have_http_status(:not_found)
          expect(response.content_type).to eq('text/html; charset=utf-8')
          expect(response.body).to eq(expected_body)
          expect(comparable_headers).to eq(expected_headers)
          expect(response.location).to be_nil
          expect(response.body).not_to include(new_user_session_path)
          expect(response.body).not_to include('admin')
          expect(response.body).not_to include('管理者')
          expect(response.body).not_to include('forbidden')
        end
      end
    end

    it '非ログインユーザーのadmin JSON requestも通常404と同じ応答にする' do
      json_headers = { 'ACCEPT' => 'application/json' }

      get '/no_such_page', headers: json_headers
      expected_body = response.body
      expected_headers = comparable_headers

      get admin_root_path, headers: json_headers

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.location).to be_nil
      end
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

    it 'guestユーザーには404を返す' do
      guest = create(:user, guest: true)
      sign_in guest

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
      allow(Analysis).to receive(:retry_receipt_analysis)
      allow(ExternalServices).to receive(:status_snapshot).and_return(
        ocr: {
          state: 'down',
          text: I18n.t('shared.service_status.down'),
          monitoring: true,
          checked_at: '2026-05-26T12:00:00+09:00',
          next_check_at: '2026-05-26T12:05:00+09:00',
          message: 'https://status.example.test/providers/ocr/service-status?incident=very-long-provider-message'
        },
        ai: {
          state: 'ok',
          text: I18n.t('shared.service_status.ok'),
          monitoring: false,
          checked_at: '2026-05-26T12:00:00+09:00',
          next_check_at: nil
        },
        upload: { allowed: false, ocr_available: false },
        notices: { ocr_down: true, ai_down: false }
      )
      allow(Storage).to receive(:system_usage_snapshot).and_return(
        total_blob_count: 3,
        attached_blob_count: 2,
        orphan_blob_count: 1,
        total_blob_bytes: 24.kilobytes,
        attached_blob_bytes: 20.kilobytes,
        orphan_blob_bytes: 4.kilobytes,
        user_count: 1,
        quota_total_bytes: 1.gigabyte,
        quota_used_bytes: 20.kilobytes
      )

      get admin_root_path
      document = Nokogiri::HTML(response.body)
      height_matched_cards = document.css('section.surface-card-blur.h-full.flex.flex-col')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('管理トップ')
        expect(response.body).to include('解析状況')
        expect(response.body).to include('Cleanup / retention')
        expect(response.body).to include('監査ログ')
        expect(response.body).to include('問い合わせ')
        expect(response.body).to include('セキュリティ / 再認証')
        expect(response.body).to include('外部サービス状態')
        expect(response.body).to include('OCRサービス')
        expect(response.body).to include('AIサービス')
        expect(response.body).to include('停止中')
        expect(response.body).to include('OCR停止中のため停止')
        expect(response.body).to include('data-controller="service-status-polling"')
        expect(response.body).to include(%(data-service-status-polling-status-url-value="#{admin_external_services_status_path}"))
        expect(response.body).to include('data-action="service-status-polling#pollNow"')
        expect(document.at_css('[data-controller="service-status-polling"].h-full')).to be_present
        expect(document.at_css('[data-service-status-polling-target="serviceStatusCard"].h-full')).to be_present
        expect(height_matched_cards.size).to be >= 7
        expect(response.body).to include('更新')
        expect(response.body).to include('ストレージ状態')
        expect(response.body).to include('total blobs')
        expect(response.body).to include('unattached')
        expect(response.body).to include('24KB')
        expect(response.body).to include('4KB')
        expect(response.body).to include('システム運用')
        expect(response.body).to include('管理トップでは直接実行しない操作')
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
        expect(response.body).to include('min-w-0 max-w-full break-words rounded-lg border token-border-soft token-bg-card-subtle p-3 font-mono token-text-base [overflow-wrap:anywhere]')
        expect(response.body).to include('min-w-0 max-w-full break-words rounded-lg border token-border-soft px-3 py-2 font-mono text-xs token-text-muted [overflow-wrap:anywhere]')
        expect(response.body).to include('receipt_analysis_run_stale_cleanup_dry_run')
        expect(response.body).to include('flex min-w-0 items-center justify-between gap-3')
        expect(response.body).to include('shrink-0 whitespace-nowrap font-mono token-text-base')
        expect(response.body).to include('break-words text-xs leading-relaxed token-text-muted [overflow-wrap:anywhere]')
        expect(response.body).to include('機能公開設定の変更')
        expect(response.body).not_to include('_HORIZONTAL')
        expect(response.body).not_to include('sliders_horizontal')
        expect(response.body).not_to include('token-border-danger')
        expect(response.body).not_to include('token-bg-danger-soft')
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

    it 'login_restricted中でもadminユーザーは総合トップを閲覧できる' do
      admin = create(:user, :admin)
      sign_in admin
      create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))
      allow(SystemOperations).to receive(:execute_receipt_analysis_cleanup)
      allow(Analysis).to receive(:retry_receipt_analysis)
      allow(ExternalServices).to receive(:status_snapshot).and_return(
        ocr: { state: 'ok', text: I18n.t('shared.service_status.ok'), monitoring: false, checked_at: nil, next_check_at: nil },
        ai: { state: 'ok', text: I18n.t('shared.service_status.ok'), monitoring: false, checked_at: nil, next_check_at: nil },
        upload: { allowed: true, ocr_available: true },
        notices: { ocr_down: false, ai_down: false }
      )
      allow(Storage).to receive(:system_usage_snapshot).and_return(
        total_blob_count: 0,
        attached_blob_count: 0,
        orphan_blob_count: 0,
        total_blob_bytes: 0,
        attached_blob_bytes: 0,
        orphan_blob_bytes: 0,
        user_count: 0,
        quota_total_bytes: 1.gigabyte,
        quota_used_bytes: 0
      )

      get admin_root_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('管理トップ')
        expect(response.body).to include('システム運用')
        expect(response.body).to include(admin_system_settings_path)
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

  describe 'GET /admin/external_services/status' do
    it 'admin向けに外部サービスカードHTMLをJSONで返す' do
      admin = create(:user, :admin)
      sign_in admin
      allow(ExternalServices).to receive(:status_snapshot).and_return(
        ocr: {
          state: 'down',
          text: I18n.t('shared.service_status.down'),
          monitoring: true,
          checked_at: '2026-05-26T12:00:00+09:00',
          next_check_at: '2026-05-26T12:05:00+09:00'
        },
        ai: {
          state: 'ok',
          text: I18n.t('shared.service_status.ok'),
          monitoring: false,
          checked_at: '2026-05-26T12:00:00+09:00',
          next_check_at: nil
        },
        upload: { allowed: false, ocr_available: false },
        notices: { ocr_down: true, ai_down: false }
      )

      get admin_external_services_status_path, as: :json

      html = response.parsed_body['html']
      document = Nokogiri::HTML.fragment(html)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(html).to include('外部サービス状態')
        expect(html).to include('OCRサービス')
        expect(html).to include('AIサービス')
        expect(html).to include('停止中')
        expect(html).to include('OCR停止中のため停止')
        expect(html).to include('data-action="service-status-polling#pollNow"')
        expect(document.at_css('section.surface-card-blur.h-full.flex.flex-col')).to be_present
      end
    end

    it '未ログインユーザーには404を返す' do
      get admin_external_services_status_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.location).to be_nil
        expect(response.body).to include(I18n.t('errors.not_found.title'))
        expect(response.body).not_to include('外部サービス状態')
      end
    end

    it '一般ユーザーは404にする' do
      user = create(:user)
      sign_in user

      get admin_external_services_status_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.body).to include(I18n.t('errors.not_found.title'))
        expect(response.body).not_to include('外部サービス状態')
      end
    end
  end
end
