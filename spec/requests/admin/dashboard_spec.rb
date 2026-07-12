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
    expect(SystemOperations).not_to have_received(:execute_receipt_analysis_retry)
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
      allow(SystemOperations).to receive(:execute_receipt_analysis_retry)
      allow(ExternalServices).to receive(:status_snapshot).with(include_details: true).and_return(
        ocr: {
          state: 'down',
          text: I18n.t('shared.service_status.down'),
          monitoring: true,
          checked_at: '2026-05-26T12:00:00+09:00',
          next_check_at: '2026-05-26T12:05:00+09:00',
          last_error_code: 'external_service_quota_exceeded',
          http_status: 403,
          provider_error_code: 'QuotaExceeded',
          provider_error_type: 'quota',
          policy_id: 'formrec_freetier_quota_id',
          region: 'Japan East',
          retry_after: 60,
          retry_after_at: '2026-05-26T12:01:00+09:00',
          request_id: 'azure-request-id',
          provider_message_safe: 'F0 quota exceeded for [FILTERED]',
          quota_exceeded: true,
          rate_limited: false,
          auth_error: false,
          message: 'https://status.example.test/providers/ocr/service-status?incident=very-long-provider-message'
        },
        ai: {
          state: 'down',
          text: I18n.t('shared.service_status.down'),
          monitoring: false,
          checked_at: '2026-05-26T12:00:00+09:00',
          next_check_at: nil
        },
        upload: { allowed: false, ocr_available: false },
        notices: { ocr_down: true, ai_down: true }
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
        quota_used_bytes: 20.kilobytes,
        global_quota: {
          used_bytes: 24.kilobytes,
          hard_stop_bytes: 20.gigabytes,
          warning_percentage: 75,
          critical_percentage: 90,
          warning_bytes: 15.gigabytes,
          critical_bytes: 18.gigabytes,
          remaining_bytes: 20.gigabytes - 24.kilobytes,
          usage_percentage: 0.00012,
          state: :normal
        }
      )
      allow(Admin).to receive(:database_status_snapshot).and_return(
        primary: 'ok',
        migration: 'current',
        database_time: Time.zone.parse('2026-05-26 12:00:00')
      )

      get admin_root_path
      document = Nokogiri::HTML(response.body)
      height_matched_cards = document.css('section.surface-card-blur.h-full.flex.flex-col')
      admin_navigation = document.at_css('nav.admin-navigation')
      admin_navigation_links = admin_navigation.css('a.admin-navigation-link')
      admin_navigation_labels = admin_navigation.css('.admin-navigation-label')
      current_admin_navigation_link = admin_navigation.at_css('a[aria-current="page"]')
      inactive_admin_navigation_link = admin_navigation_links.find { |link| link['href'] == admin_users_path }
      announcements_admin_navigation_link = admin_navigation_links.find { |link| link['href'] == admin_announcements_path }
      ip_blocks_admin_navigation_link = admin_navigation_links.find { |link| link['href'] == admin_ip_blocks_path }
      back_admin_navigation_link = admin_navigation.at_css('a.admin-navigation-back')
      tailwind_css = expanded_tailwind_source

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('管理トップ')
        expect(response.body).to include('解析状況')
        expect(response.body).to include('Cleanup / retention')
        expect(response.body).to include('監査ログ')
        expect(response.body).to include('問い合わせ')
        expect(response.body).to include('セキュリティ')
        expect(response.body).to include('セキュリティイベント')
        expect(response.body).to include('未対応イベント')
        expect(response.body).to include('high / critical')
        expect(response.body).to include('外部サービス状態')
        expect(response.body).to include('OCRサービス')
        expect(response.body).to include('AIサービス')
        expect(response.body).to include('停止中')
        expect(response.body).to include('external_service_quota_exceeded')
        expect(response.body).to include('403')
        expect(response.body).to include('QuotaExceeded')
        expect(response.body).to include('quota')
        expect(response.body).to include('formrec_freetier_quota_id')
        expect(response.body).to include('Japan East')
        expect(response.body).to include('05/26 12:01')
        expect(response.body).to include('azure-request-id')
        expect(response.body).to include('quota exceeded')
        expect(response.body).to include('rate limited')
        expect(response.body).to include('auth error')
        expect(response.body).to include('F0 quota exceeded for [FILTERED]')
        expect(response.body).to include('OCR停止中のため停止')
        expect(response.body).to include('data-controller="service-status-polling"')
        expect(response.body).to include(%(data-service-status-polling-status-url-value="#{admin_external_services_status_path}"))
        expect(response.body).to include('data-action="service-status-polling#pollNow"')
        expect(document.at_css('[data-controller="service-status-polling"].h-full')).to be_present
        expect(document.at_css('[data-service-status-polling-target="serviceStatusCard"].h-full')).to be_present
        expect(admin_navigation).to be_present
        expect(admin_navigation_links.size).to eq(12)
        expect(admin_navigation_links.all? { |link| link['aria-label'].present? }).to be(true)
        expect(admin_navigation_links.none? { |link| link['class'].include?('hover:underline') }).to be(true)
        expect(admin_navigation_labels.size).to eq(12)
        expect(announcements_admin_navigation_link).to be_present
        expect(announcements_admin_navigation_link.text).to include('お知らせ')
        expect(ip_blocks_admin_navigation_link).to be_present
        expect(ip_blocks_admin_navigation_link.text).to include('IP制限')
        expect(current_admin_navigation_link['href']).to eq(admin_root_path)
        expect(current_admin_navigation_link['class']).to include('admin-navigation-current')
        expect(current_admin_navigation_link['class']).to include('token-text-brand')
        expect(current_admin_navigation_link['class']).to include('token-brand-soft-bg')
        expect(inactive_admin_navigation_link['class']).to include('token-text-muted')
        expect(inactive_admin_navigation_link['class']).to include('token-hover-text-brand')
        expect(back_admin_navigation_link['class']).to include('token-text-muted')
        expect(back_admin_navigation_link['class']).to include('token-hover-text-base')
        expect(tailwind_css).to include('@media (height <= 700px) and (width <= 380px)')
        expect(tailwind_css).to include('.admin-navigation-label')
        expect(tailwind_css).to include('.admin-navigation-current')
        expect(height_matched_cards.size).to be >= 7
        expect(response.body).to include('更新')
        expect(response.body).to include('ストレージ状態')
        expect(response.body).to include('全体ストレージ上限')
        expect(response.body).to include('total blobs')
        expect(response.body).to include('unattached')
        expect(response.body).to include('24KB')
        expect(response.body).to include('4KB')
        expect(response.body).to include('15GB')
        expect(response.body).to include('18GB')
        expect(response.body).to include('20GB')
        expect(response.body).to include('法務文書')
        expect(response.body).to include('同期済み')
        expect(response.body).to include('利用規約')
        expect(response.body).to include('プライバシーポリシー')
        expect(response.body).to include('DB状態')
        expect(response.body).to include('データベース接続とschema状態')
        expect(response.body).to include('Primary DB')
        expect(response.body).to include('Migration')
        expect(response.body).to include('DB時刻')
        expect(response.body).to include('正常')
        expect(response.body).to include('最新')
        expect(response.body).to include('このカードではDB操作やmigrationは実行しません。')
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
        expect(response.body).to include('grid min-w-0 max-w-full gap-6 overflow-hidden lg:grid-cols-2')
        expect(response.body).to include('min-w-0 max-w-full overflow-hidden break-words rounded-lg border token-border-soft token-bg-card-subtle p-3 font-mono token-text-base [overflow-wrap:anywhere]')
        expect(response.body).to include('min-w-0 max-w-full overflow-hidden break-words rounded-lg border token-border-soft token-bg-card-subtle p-3 token-text-base [overflow-wrap:anywhere]')
        expect(response.body).to include('inline-flex min-w-0 max-w-full overflow-hidden break-words whitespace-normal rounded-lg border token-border-soft px-3 py-2 font-mono text-xs token-text-muted [overflow-wrap:anywhere]')
        expect(response.body).to include('receipt_analysis_run_stale_cleanup_dry_run')
        expect(response.body).to include('flex min-w-0 flex-wrap items-center justify-between gap-x-3 gap-y-1')
        expect(response.body).to include('min-w-0 break-words font-mono token-text-base [overflow-wrap:anywhere]')
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

    it 'current法務文書が未同期の場合もadmin dashboardに警告を表示する' do
      admin = create(:user, :admin)
      sign_in admin
      allow(LegalDocuments).to receive(:current_status).and_return(
        LegalDocuments::CurrentStatus::Result.new(
          ready: false,
          locale: 'ja',
          documents: {
            'terms' => { document_type: 'terms', locale: 'ja', present: false },
            'privacy' => { document_type: 'privacy', locale: 'ja', present: false }
          },
          missing_types: [ 'terms', 'privacy' ],
          checked_at: Time.zone.parse('2026-05-26 12:00:00')
        )
      )

      get admin_root_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('法務文書')
        expect(response.body).to include('不足あり')
        expect(response.body).to include('currentなし')
        expect(response.body).to include('DB同期が必要です')
        expect(response.body).to include('bin/rails legal_documents:verify_files')
        expect(response.body).to include('bin/rails legal_documents:sync')
        expect(response.body).to include('bin/rails legal_documents:verify')
      end
    end

    it '問い合わせ通知先が未設定の場合はadmin dashboardに警告を表示する' do
      admin = create(:user, :admin)
      sign_in admin
      allow(ContactRequestMailer).to receive(:admin_notification_enabled?).and_return(false)

      get admin_root_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('管理通知先が未設定です')
        expect(response.body).to include('問い合わせ受付と自動返信は継続します')
        expect(response.body).to include('SUPPORT_NOTIFICATION_EMAIL')
      end
    end

    it '問い合わせ通知先が設定済みの場合はadmin dashboardに通知先未設定警告を表示しない' do
      admin = create(:user, :admin)
      sign_in admin
      allow(ContactRequestMailer).to receive(:admin_notification_enabled?).and_return(true)

      get admin_root_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to include('管理通知先が未設定です')
        expect(response.body).not_to include('SUPPORT_NOTIFICATION_EMAIL')
      end
    end

    it 'login_restricted中でもadminユーザーは総合トップを閲覧できる' do
      admin = create(:user, :admin)
      sign_in admin
      create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))
      allow(SystemOperations).to receive(:execute_receipt_analysis_cleanup)
      allow(SystemOperations).to receive(:execute_receipt_analysis_retry)
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
        quota_used_bytes: 0,
        global_quota: {
          used_bytes: 0,
          hard_stop_bytes: 20.gigabytes,
          warning_percentage: 75,
          critical_percentage: 90,
          warning_bytes: 15.gigabytes,
          critical_bytes: 18.gigabytes,
          remaining_bytes: 20.gigabytes,
          usage_percentage: 0.0,
          state: :normal
        }
      )
      allow(Admin).to receive(:database_status_snapshot).and_return(
        primary: 'ok',
        migration: 'current',
        database_time: Time.zone.parse('2026-05-26 12:00:00')
      )

      get admin_root_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('管理トップ')
        expect(response.body).to include('システム運用')
        expect(response.body).to include(admin_system_settings_path)
      end
    end

    it 'DB状態確認に失敗してもdashboard全体は表示し確認不可を出す' do
      admin = create(:user, :admin)
      sign_in admin
      allow(Admin).to receive(:database_status_snapshot).and_return(
        primary: 'unavailable',
        migration: 'unavailable',
        database_time: nil
      )

      get admin_root_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('管理トップ')
        expect(response.body).to include('DB状態')
        expect(response.body).to include('確認不可')
        expect(response.body).to include('DB時刻')
        expect(response.body).to include('-')
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
          disabled: true,
          source: 'system_setting',
          monitoring: true,
          checked_at: '2026-05-26T12:00:00+09:00',
          next_check_at: '2026-05-26T12:05:00+09:00',
          last_error_code: 'external_service_auth_error',
          provider_error_code: 'Unauthorized',
          request_id: 'azure-request-id',
          provider_message_safe: 'invalid key'
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
        expect(html).to include('運用停止')
        expect(html).to include('external_service_auth_error')
        expect(html).to include('Unauthorized')
        expect(html).to include('azure-request-id')
        expect(html).to include('invalid key')
        expect(html).to include('OCR停止中のため停止')
        expect(html).not_to include(I18n.t('admin.dashboard.external_services.ocr_only_fallback'))
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
