require 'rails_helper'
require 'webauthn/fake_client'

RSpec.describe 'Admin system settings', type: :request do
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

  def expect_no_side_effects
    forbidden_jobs = [
      ReceiptOcrJob,
      ReceiptAiEnrichmentJob,
      ReceiptFinalizeJob,
      ReceiptAnalysisRunStaleCleanupJob,
      ReceiptAnalysisRunRetentionCleanupJob
    ]

    expect(enqueued_jobs.select { |job| forbidden_jobs.include?(job[:job]) }).to be_empty
    expect(AuditLog.count).to eq(0)
  end

  def expect_no_jobs_enqueued
    forbidden_jobs = [
      ReceiptOcrJob,
      ReceiptAiEnrichmentJob,
      ReceiptFinalizeJob,
      ReceiptAnalysisRunStaleCleanupJob,
      ReceiptAnalysisRunRetentionCleanupJob
    ]

    expect(enqueued_jobs.select { |job| forbidden_jobs.include?(job[:job]) }).to be_empty
  end

  def webauthn_client
    @webauthn_client ||= WebAuthn::FakeClient.new('http://localhost:3000')
  end

  def create_passkey_with_fake_client(user)
    options = Passkeys.registration_options(user: user)
    credential = webauthn_client.create(challenge: options.challenge, rp_id: 'localhost', user_verified: true)

    Passkeys.verify_registration(user: user, credential: credential, challenge: options.challenge)
  end

  def reauthenticate_admin_with_passkey!(admin)
    passkey = create_passkey_with_fake_client(admin)

    post options_admin_passkey_reauthentication_path, as: :json
    options = response.parsed_body.fetch('publicKey')
    credential = webauthn_client.get(
      challenge: options.fetch('challenge'),
      rp_id: 'localhost',
      user_verified: true,
      allow_credentials: [ passkey.credential_id ]
    )

    post admin_passkey_reauthentication_path,
         params: { credential: credential },
         as: :json

    expect(response).to have_http_status(:success)
  end

  describe 'GET /admin/system_settings' do
    it '非ログインユーザーには既存404と同じbody/headerを返す' do
      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      get admin_system_settings_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.location).to be_nil
        expect(response.body).not_to include('システム設定')
      end
    end

    it '一般ユーザーには既存404と同じbody/headerを返す' do
      user = create(:user)
      sign_in user

      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      sign_in user
      get admin_system_settings_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).not_to include('システム設定')
      end
    end

    it 'adminユーザーは設定一覧を閲覧できる' do
      admin = create(:user, :admin)
      create(
        :system_setting,
        key: 'feature.receipt_logo_display_enabled',
        value: SystemSettings.stored_value(true),
        updated_by_user: admin
      )
      sign_in admin

      get admin_system_settings_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('システム設定')
        expect(response.body).to include('管理対象設定')
        expect(response.body).to include('feature.receipt_logo_display_enabled')
        expect(response.body).to include('amount_engine.tax_excluded_price_conversion_enabled')
        expect(response.body).to include('limits.receipt_upload_soft_limit')
        expect(response.body).to include('limits.receipt_uploads_per_day')
        expect(response.body).to include('limits.receipt_adjustments_per_receipt')
        expect(response.body).to include('limits.receipt_total_amount_max')
        expect(response.body).to include('limits.receipt_item_price_max')
        expect(response.body).to include('limits.receipt_item_line_total_max')
        expect(response.body).to include('limits.receipt_tax_amount_max')
        expect(response.body).to include('limits.receipt_adjustment_amount_max')
        expect(response.body).to include('limits.receipt_payment_amount_max')
        expect(response.body).to include('limits.notifications_per_user')
        expect(response.body).to include('limits.batch_upload_max_files')
        expect(response.body).to include('retention.notifications_read_days')
        expect(response.body).to include('retention.guest_users_days')
        expect(response.body).to include('retention.user_sessions_days')
        expect(response.body).to include('retention.contact_requests_days')
        expect(response.body).to include('retention.analysis_runs_short_days')
        expect(response.body).to include('retention.analysis_runs_default_days')
        expect(response.body).to include('retention.analysis_runs_failed_days')
        expect(response.body).to include('retention.orphan_blobs_hours')
        expect(response.body).to include('retention.receipt_images_days')
        expect(response.body).to include('limits.snapshot_ocr_items_max')
        expect(response.body).to include('limits.snapshot_ai_normalized_items_max')
        expect(response.body).to include('limits.api_requests_per_day')
        expect(response.body).to include(admin_system_setting_path('feature.receipt_logo_display_enabled'))
        expect(response.body).not_to include('SENTRY_DSN')
        expect(response.body).not_to include('WEBAUTHN_RP_ID')
        expect(response.body).not_to include('SMTP credentials')
        expect(response.body).not_to include('API key')
        expect(response.body).not_to include('RAW OCR RESPONSE')
        expect(response.body).not_to include('FULL PROMPT')
        expect(response.body).not_to include('RAW AI RESPONSE')
        expect(response.body).not_to include('SECRET')
        expect(response.body).not_to include('name="reason"')
        expect(response.body).not_to include('設定を更新')
        expect_no_side_effects
      end
    end

    it 'login_restricted中でもadminユーザーはメンテナンス設定一覧を閲覧できる' do
      admin = create(:user, :admin)
      sign_in admin
      create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))

      get admin_system_settings_path(category: 'maintenance')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('システム設定')
        expect(response.body).to include('maintenance.mode')
        expect(response.body).to include('maintenance.title')
        expect(response.body).to include('maintenance.body')
      end
    end

    it 'snapshot件数上限をhigh risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('limits.snapshot_ocr_items_max')

      document = Nokogiri::HTML(response.body)
      note = document.at_css('p.token-bg-warning-soft')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('limits.snapshot_ocr_items_max')
        expect(response.body).to include('snapshot_limit')
        expect(response.body).to include('high')
        expect(response.body).to include('100')
        expect(response.body).to include('10000')
        expect(response.body).to include('1000')
        expect(note.text).to include('snapshot上限を大きくすると解析snapshotのjsonbサイズが増えます')
        expect(note.text).to include('receipt_items_per_receipt の最大値以上')
        expect(note['class']).to include('min-w-0')
        expect(note['class']).to include('[overflow-wrap:anywhere]')
      end
    end

    it '税抜単価の税込補正切り替えをhigh risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('amount_engine.tax_excluded_price_conversion_enabled')

      document = Nokogiri::HTML(response.body)
      note = document.at_css('p.token-bg-warning-soft')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('amount_engine.tax_excluded_price_conversion_enabled')
        expect(response.body).to include('amount_engine')
        expect(response.body).to include('boolean')
        expect(response.body).to include('high')
        expect(response.body).to include('true')
        expect(note.text).to include('OCR/AI解析時に税抜と判断した明細を税込のprice/line_totalへ補正')
        expect(note.text).to include('手動作成・編集保存には適用されません')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).not_to include('name="reason"')
      end
    end

    it '調整行件数上限をmedium risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('limits.receipt_adjustments_per_receipt')

      document = Nokogiri::HTML(response.body)
      note = document.at_css('p.token-bg-warning-soft')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('limits.receipt_adjustments_per_receipt')
        expect(response.body).to include('usage_limit')
        expect(response.body).to include('medium')
        expect(response.body).to include('0')
        expect(response.body).to include('200')
        expect(response.body).to include('50')
        expect(note.text).to include('1レシートに保存できる調整行の最大数')
        expect(note.text).to include('大きくしすぎると金額計算や確認画面が重くなる可能性')
        expect(note['class']).to include('min-w-0')
        expect(note['class']).to include('[overflow-wrap:anywhere]')
      end
    end

    it '管理者再認証期間をhigh risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('security.admin_passkey_reauth_window_minutes')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('security.admin_passkey_reauth_window_minutes')
        expect(response.body).to include('security')
        expect(response.body).to include('high')
        expect(response.body).to include('1')
        expect(response.body).to include('60')
        expect(response.body).to include('5')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).not_to include('name="reason"')
      end
    end

    it '利用上限のシステム上限をhigh risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('limits.max_ocr_per_day')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('limits.max_ocr_per_day')
        expect(response.body).to include('usage_limit_safety')
        expect(response.body).to include('high')
        expect(response.body).to include('50')
        expect(response.body).to include('10000')
        expect(response.body).to include('1000')
        expect(response.body).to include('アップロード、OCR、AI、ストレージのコストに直結')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).not_to include('name="reason"')
      end
    end

    it '支払い情報上限をmedium risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('limits.receipt_payments_per_receipt')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('limits.receipt_payments_per_receipt')
        expect(response.body).to include('usage_limit')
        expect(response.body).to include('medium')
        expect(response.body).to include('0')
        expect(response.body).to include('100')
        expect(response.body).to include('20')
        expect(response.body).to include('OCRのPayments配列が異常に多い場合')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).not_to include('name="reason"')
      end
    end

    it '税区分上限をmedium risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('limits.receipt_tax_details_per_receipt')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('limits.receipt_tax_details_per_receipt')
        expect(response.body).to include('usage_limit')
        expect(response.body).to include('medium')
        expect(response.body).to include('0')
        expect(response.body).to include('100')
        expect(response.body).to include('20')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).not_to include('name="reason"')
      end
    end

    it '金額上限をhigh risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('limits.receipt_total_amount_max')

      document = Nokogiri::HTML(response.body)
      note = document.at_css('p.token-bg-warning-soft')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('limits.receipt_total_amount_max')
        expect(response.body).to include('amount_limit')
        expect(response.body).to include('high')
        expect(response.body).to include('1')
        expect(response.body).to include('999999999999')
        expect(response.body).to include('999999999')
        expect(note.text).to include('金額系フィールドのアプリ上限')
        expect(note.text).to include('DBはbigint')
        expect(note['class']).to include('min-w-0')
        expect(note['class']).to include('[overflow-wrap:anywhere]')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).not_to include('name="reason"')
      end
    end

    it '通知保持件数上限をmedium risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('limits.notifications_per_user')

      document = Nokogiri::HTML(response.body)
      note = document.at_css('p.token-bg-warning-soft')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('limits.notifications_per_user')
        expect(response.body).to include('usage_limit')
        expect(response.body).to include('medium')
        expect(response.body).to include('20')
        expect(response.body).to include('500')
        expect(response.body).to include('100')
        expect(note.text).to include('1ユーザーあたりDBに保持する通知の最大件数')
        expect(note.text).to include('通知一覧の1回表示件数とは別')
        expect(note['class']).to include('min-w-0')
        expect(note['class']).to include('[overflow-wrap:anywhere]')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).not_to include('name="reason"')
      end
    end

    it '一括アップロード件数上限をmedium risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('limits.batch_upload_max_files')

      document = Nokogiri::HTML(response.body)
      note = document.at_css('p.token-bg-warning-soft')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('limits.batch_upload_max_files')
        expect(response.body).to include('usage_limit')
        expect(response.body).to include('medium')
        expect(response.body).to include('1')
        expect(response.body).to include('20')
        expect(response.body).to include('5')
        expect(note.text).to include('1回の操作でアップロードできる最大ファイル数')
        expect(note.text).to include('日次アップロード上限、OCR/AIの日次上限、ストレージ上限とは別設定')
        expect(note['class']).to include('min-w-0')
        expect(note['class']).to include('[overflow-wrap:anywhere]')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).not_to include('name="reason"')
      end
    end

    it '既読通知保持期間をmedium risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('retention.notifications_read_days')

      document = Nokogiri::HTML(response.body)
      note = document.at_css('p.token-bg-warning-soft')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('retention.notifications_read_days')
        expect(response.body).to include('retention')
        expect(response.body).to include('medium')
        expect(response.body).to include('1')
        expect(response.body).to include('365')
        expect(response.body).to include('30')
        expect(note.text).to include('既読通知を保持する日数')
        expect(note.text).to include('未読通知はこの保持期間では削除されません')
        expect(note.text).to include('1ユーザーあたりの通知保持件数とは別設定')
        expect(note['class']).to include('min-w-0')
        expect(note['class']).to include('[overflow-wrap:anywhere]')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).not_to include('name="reason"')
      end
    end

    it 'ゲスト保持期間をmedium risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('retention.guest_users_days')

      document = Nokogiri::HTML(response.body)
      note = document.at_css('p.token-bg-warning-soft')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('retention.guest_users_days')
        expect(response.body).to include('retention')
        expect(response.body).to include('medium')
        expect(response.body).to include('1')
        expect(response.body).to include('90')
        expect(response.body).to include('7')
        expect(note.text).to include('ゲストユーザーと関連データを保持する日数')
        expect(note.text).to include('ストレージ使用量も増える可能性')
        expect(note['class']).to include('min-w-0')
        expect(note['class']).to include('[overflow-wrap:anywhere]')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).not_to include('name="reason"')
      end
    end

    it 'セッション保持期間をmedium risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('retention.user_sessions_days')

      document = Nokogiri::HTML(response.body)
      note = document.at_css('p.token-bg-warning-soft')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('retention.user_sessions_days')
        expect(response.body).to include('retention')
        expect(response.body).to include('medium')
        expect(response.body).to include('30')
        expect(response.body).to include('365')
        expect(response.body).to include('90')
        expect(note.text).to include('ユーザーセッション履歴を保持する日数')
        expect(note.text).to include('active session保護期間(30日)以上')
        expect(note['class']).to include('min-w-0')
        expect(note['class']).to include('[overflow-wrap:anywhere]')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).not_to include('name="reason"')
      end
    end

    it '問い合わせ保持期間をmedium risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('retention.contact_requests_days')

      document = Nokogiri::HTML(response.body)
      note = document.at_css('p.token-bg-warning-soft')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('retention.contact_requests_days')
        expect(response.body).to include('retention')
        expect(response.body).to include('medium')
        expect(response.body).to include('30')
        expect(response.body).to include('730')
        expect(response.body).to include('180')
        expect(note.text).to include('解決済みまたはクローズ済み問い合わせのPIIを匿名化するまでの日数')
        expect(note.text).to include('hard deleteではなく匿名化')
        expect(note['class']).to include('min-w-0')
        expect(note['class']).to include('[overflow-wrap:anywhere]')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).not_to include('name="reason"')
      end
    end

    it '解析run保持期間をmedium risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      {
        'retention.analysis_runs_short_days' => '14',
        'retention.analysis_runs_default_days' => '30',
        'retention.analysis_runs_failed_days' => '90'
      }.each do |key, default_value|
        get admin_system_setting_path(key)

        document = Nokogiri::HTML(response.body)
        note = document.at_css('p.token-bg-warning-soft')

        aggregate_failures key do
          expect(response).to have_http_status(:success)
          expect(response.body).to include(key)
          expect(response.body).to include('retention')
          expect(response.body).to include('medium')
          expect(response.body).to include('1')
          expect(response.body).to include('365')
          expect(response.body).to include(default_value)
          expect(note.text).to include('解析runのexpires_at計算に使う保持期間')
          expect(note.text).to include('failed >= default >= short')
          expect(note['class']).to include('min-w-0')
          expect(note['class']).to include('[overflow-wrap:anywhere]')
          expect(response.body).to include('パスキー再認証')
          expect(response.body).not_to include('name="reason"')
        end
      end
    end

    it 'orphan blob保持期間をhigh risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('retention.orphan_blobs_hours')

      document = Nokogiri::HTML(response.body)
      note = document.at_css('p.token-bg-warning-soft')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('retention.orphan_blobs_hours')
        expect(response.body).to include('retention')
        expect(response.body).to include('high')
        expect(response.body).to include('24')
        expect(response.body).to include('720')
        expect(response.body).to include('48')
        expect(note.text).to include('添付されていないBlobを削除対象とみなすまでの時間')
        expect(note.text).to include('実ファイル削除に影響する高リスク設定')
        expect(note['class']).to include('min-w-0')
        expect(note['class']).to include('[overflow-wrap:anywhere]')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).not_to include('name="reason"')
      end
    end

    it 'レシート画像保持期間をhigh risk設定として表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('retention.receipt_images_days')

      document = Nokogiri::HTML(response.body)
      note = document.at_css('p.token-bg-warning-soft')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('retention.receipt_images_days')
        expect(response.body).to include('retention')
        expect(response.body).to include('high')
        expect(response.body).to include('1')
        expect(response.body).to include('365')
        expect(note.text).to include('keep_image=false のレシート画像を削除対象とみなすまでの日数')
        expect(note.text).to include('実ファイル削除に影響する高リスク設定')
        expect(note['class']).to include('min-w-0')
        expect(note['class']).to include('[overflow-wrap:anywhere]')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).not_to include('name="reason"')
      end
    end
  end

  describe 'GET /admin/system_settings/:key' do
    it 'adminユーザーはdot入りkeyの詳細を閲覧できる' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('limits.receipt_upload_soft_limit')

      document = Nokogiri::HTML(response.body)
      current_value = document.at_css('dd')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('limits.receipt_upload_soft_limit')
        expect(response.body).to include('soft_limit')
        expect(response.body).to include('100')
        expect(response.body).to include(admin_audit_logs_path(target_uid: 'limits.receipt_upload_soft_limit'))
        expect(response.body).not_to include('SENTRY_DSN')
        expect(response.body).not_to include('WEBAUTHN_RP_ID')
        expect(response.body).not_to include('name="reason"')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).not_to include('設定を更新')
        expect(response.body).to include('min-w-0 max-w-full overflow-hidden rounded-lg border')
        expect(current_value['class']).to include('min-w-0')
        expect(current_value['class']).to include('[overflow-wrap:anywhere]')
        expect(current_value['class']).to include('text-base')
        expect(current_value['class']).to include('md:text-lg')
        expect_no_side_effects
      end
    end

    it 'adminユーザーは新しいusage limit定義の詳細を閲覧できる' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('limits.receipt_uploads_per_day')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('limits.receipt_uploads_per_day')
        expect(response.body).to include('usage_limit')
        expect(response.body).to include('50')
        expect(response.body).to include(admin_audit_logs_path(target_uid: 'limits.receipt_uploads_per_day'))
        expect(response.body).not_to include('SENTRY_DSN')
        expect(response.body).not_to include('WEBAUTHN_RP_ID')
        expect(response.body).not_to include('name="reason"')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).not_to include('設定を更新')
        expect_no_side_effects
      end
    end

    it 'fresh reauth済みならeditable keyの更新フォームを表示する' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      get admin_system_setting_path('feature.receipt_logo_display_enabled')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('設定を更新')
        expect(response.body).to include('name="value"')
        expect(response.body).to include('name="reason"')
        expect(response.body).not_to include('SENTRY_DSN')
        expect(response.body).not_to include('WEBAUTHN_RP_ID')
      end
    end

    it 'お知らせタイトルはtext fieldで表示する' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      get admin_system_setting_path('ui.maintenance_notice_title')

      document = Nokogiri::HTML(response.body)
      input = document.at_css('input[name="value"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(input).to be_present
        expect(input['maxlength']).to eq('80')
        expect(document.at_css('textarea[name="value"]')).to be_nil
      end
    end

    it 'お知らせ本文はtextareaで表示する' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      get admin_system_setting_path('ui.maintenance_notice_body')

      document = Nokogiri::HTML(response.body)
      textarea = document.at_css('textarea[name="value"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(textarea).to be_present
        expect(textarea['maxlength']).to eq('1000')
        expect(textarea['class']).to include('py-2')
        expect(textarea['class']).to include('leading-6')
        expect(document.at_css('input[name="value"]')).to be_nil
      end
    end

    it 'メンテナンス本文はtextareaで表示する' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      get admin_system_setting_path('maintenance.body')

      document = Nokogiri::HTML(response.body)
      textarea = document.at_css('textarea[name="value"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(textarea).to be_present
        expect(textarea['maxlength']).to eq('1000')
        expect(textarea['class']).to include('py-2')
        expect(textarea['class']).to include('leading-6')
        expect(document.at_css('input[name="value"]')).to be_nil
      end
    end

    it '存在しないkeyは404にする' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('secret.provider_api_key')

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'PATCH /admin/system_settings/:key' do
    it 'fresh reauthなしでは更新せず、再認証へredirectする' do
      admin = create(:user, :admin)
      sign_in admin
      allow(SystemOperations).to receive(:update_setting)

      patch admin_system_setting_path('feature.receipt_logo_display_enabled'),
            params: {
              value: 'true',
              reason: 'enable logo'
            }

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_system_setting_path('feature.receipt_logo_display_enabled')))
        expect(flash[:alert]).to include('パスキーによる再認証')
        expect(SystemOperations).not_to have_received(:update_setting)
        expect(SystemSetting.find_by(key: 'feature.receipt_logo_display_enabled')).to be_nil
        expect(session.to_hash.to_json).not_to include('enable logo', 'true')
        expect_no_jobs_enqueued
      end
    end

    it '設定された再認証期間を過ぎると高リスク設定更新を拒否する' do
      create(:system_setting, key: 'security.admin_passkey_reauth_window_minutes', value: SystemSettings.stored_value(1))
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)
      allow(SystemOperations).to receive(:update_setting)

      travel 2.minutes do
        patch admin_system_setting_path('feature.receipt_logo_display_enabled'),
              params: {
                value: 'true',
                reason: 'expired reauth'
              }
      end

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_system_setting_path('feature.receipt_logo_display_enabled')))
        expect(flash[:alert]).to include('パスキーによる再認証')
        expect(SystemOperations).not_to have_received(:update_setting)
        expect(SystemSetting.find_by(key: 'feature.receipt_logo_display_enabled')).to be_nil
      end
    end

    it 'reason blankでは更新しない' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)
      allow(SystemOperations).to receive(:update_setting)

      patch admin_system_setting_path('feature.receipt_logo_display_enabled'),
            params: {
              value: 'true',
              reason: ' '
            }

      aggregate_failures do
        expect(response).to redirect_to(admin_system_setting_path('feature.receipt_logo_display_enabled'))
        expect(flash[:alert]).to include('変更理由')
        expect(SystemOperations).not_to have_received(:update_setting)
        expect(SystemSetting.find_by(key: 'feature.receipt_logo_display_enabled')).to be_nil
      end
    end

    it 'editable keyはSystemOperations経由で更新する' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)
      result = SystemOperations::Result.new(success: true)
      allow(SystemOperations).to receive(:update_setting).and_return(result)

      patch admin_system_setting_path('feature.receipt_logo_display_enabled'),
            params: {
              value: 'true',
              reason: 'enable logo',
              confirm: '1'
            },
            headers: { 'HTTP_USER_AGENT' => 'System Settings Request Spec' }

      aggregate_failures do
        expect(response).to redirect_to(admin_system_setting_path('feature.receipt_logo_display_enabled'))
        expect(flash[:notice]).to include('設定を更新しました')
        expect(SystemOperations).to have_received(:update_setting).with(
          key: 'feature.receipt_logo_display_enabled',
          value: 'true',
          actor: admin,
          reason: 'enable logo',
          request: kind_of(ActionDispatch::Request),
          reauthentication: hash_including(method: 'passkey', reauthenticated_at: kind_of(Time)),
          confirmation: '1'
        )
        expect(SystemSetting.find_by(key: 'feature.receipt_logo_display_enabled')).to be_nil
        expect_no_jobs_enqueued
      end
    end

    it '実SystemOperations経由で更新し、AuditLogを作成する' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      expect {
        patch admin_system_setting_path('limits.receipt_upload_soft_limit'),
              params: {
                value: '250',
                reason: 'upload support'
              },
              headers: { 'HTTP_USER_AGENT' => 'System Settings Request Spec' }
      }.to change(AuditLog, :count).by(1)

      setting = SystemSetting.find_by!(key: 'limits.receipt_upload_soft_limit')
      audit_log = AuditLog.last

      aggregate_failures do
        expect(response).to redirect_to(admin_system_setting_path('limits.receipt_upload_soft_limit'))
        expect(setting.value).to eq('value' => 250)
        expect(setting.updated_by_user).to eq(admin)
        expect(audit_log).to have_attributes(
          action: 'system_settings.update',
          outcome: 'succeeded',
          target_type: 'SystemSetting',
          target_id: setting.id,
          target_uid: 'limits.receipt_upload_soft_limit',
          reason: 'upload support',
          user_agent: 'System Settings Request Spec'
        )
        expect(audit_log.before_state).to eq('value' => 100, 'source' => 'default')
        expect(audit_log.after_state).to eq('value' => 250, 'source' => 'db')
        expect(audit_log.metadata).to include(
          'key' => 'limits.receipt_upload_soft_limit',
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey'
        )
        expect(audit_log.attributes.to_json).not_to include('credential_id', 'challenge', 'public_key', 'secret')
      end
    end

    it '税抜単価の税込補正切り替えを実SystemOperations経由で更新する' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      expect {
        patch admin_system_setting_path('amount_engine.tax_excluded_price_conversion_enabled'),
              params: {
                value: 'false',
                reason: 'verify tax excluded conversion fallback',
                confirm: '1'
              },
              headers: { 'HTTP_USER_AGENT' => 'System Settings Request Spec' }
      }.to change(AuditLog, :count).by(1)

      setting = SystemSetting.find_by!(key: 'amount_engine.tax_excluded_price_conversion_enabled')
      audit_log = AuditLog.last

      aggregate_failures do
        expect(response).to redirect_to(admin_system_setting_path('amount_engine.tax_excluded_price_conversion_enabled'))
        expect(setting.value).to eq('value' => false)
        expect(audit_log).to have_attributes(
          action: 'system_settings.update',
          outcome: 'succeeded',
          target_uid: 'amount_engine.tax_excluded_price_conversion_enabled',
          reason: 'verify tax excluded conversion fallback'
        )
        expect(audit_log.before_state).to eq('value' => true, 'source' => 'default')
        expect(audit_log.after_state).to eq('value' => false, 'source' => 'db')
        expect(audit_log.metadata).to include(
          'category' => 'amount_engine',
          'risk_level' => 'high',
          'reauthenticated' => true
        )
      end
    end

    it '明細上限がsnapshot OCR/AI上限を超える場合は日本語の理由を表示して拒否する' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      expect {
        patch admin_system_setting_path('limits.receipt_items_per_receipt'),
              params: {
                value: '1200',
                reason: 'raise receipt item limit'
              }
      }.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(admin_system_setting_path('limits.receipt_items_per_receipt'))
        expect(flash[:alert]).to include('receipt_items_per_receipt の最大値を上げるには、先に snapshot OCR/AI 上限を同等以上に変更してください。')
        expect(SystemSetting.find_by(key: 'limits.receipt_items_per_receipt')).to be_nil
        expect(AuditLog.last).to have_attributes(
          action: 'system_settings.update',
          outcome: 'failed',
          error_code: 'receipt_items_snapshot_limit'
        )
      end
    end

    it '解析run保持期間の大小関係が崩れる場合は日本語の理由を表示して拒否する' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      expect {
        patch admin_system_setting_path('retention.analysis_runs_default_days'),
              params: {
                value: '91',
                reason: 'extend default retention'
              }
      }.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(admin_system_setting_path('retention.analysis_runs_default_days'))
        expect(flash[:alert]).to include('解析run保持期間は failed >= default >= short の関係を維持してください。')
        expect(SystemSetting.find_by(key: 'retention.analysis_runs_default_days')).to be_nil
        expect(AuditLog.last).to have_attributes(
          action: 'system_settings.update',
          outcome: 'failed',
          error_code: 'analysis_run_retention_order'
        )
      end
    end

    it '金額上限の大小関係が崩れる場合は日本語の理由を表示して拒否する' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      expect {
        patch admin_system_setting_path('limits.receipt_payment_amount_max'),
              params: {
                value: '1000000000',
                reason: 'raise payment amount max',
                confirm: '1'
              }
      }.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(admin_system_setting_path('limits.receipt_payment_amount_max'))
        expect(flash[:alert]).to include('金額上限の大小関係を維持してください')
        expect(SystemSetting.find_by(key: 'limits.receipt_payment_amount_max')).to be_nil
        expect(AuditLog.last).to have_attributes(
          action: 'system_settings.update',
          outcome: 'failed',
          error_code: 'amount_limit_relationship'
        )
      end
    end

    it '利用上限がシステム上限を超える場合は日本語の理由を表示して拒否する' do
      admin = create(:user, :admin)
      create(:system_setting, key: 'limits.max_ocr_per_day', value: SystemSettings.stored_value(100))
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      expect {
        patch admin_system_setting_path('limits.ocr_jobs_per_day'),
              params: {
                value: '101',
                reason: 'raise OCR limit'
              }
      }.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(admin_system_setting_path('limits.ocr_jobs_per_day'))
        expect(flash[:alert]).to include('UserLimitsのシステム上限を超えています')
        expect(SystemSetting.find_by(key: 'limits.ocr_jobs_per_day')).to be_nil
        expect(AuditLog.last).to have_attributes(
          action: 'system_settings.update',
          outcome: 'failed',
          error_code: 'user_limit_safety_max'
        )
      end
    end

    it 'active overrideを下回るシステム上限への変更は日本語の理由を表示して拒否する' do
      admin = create(:user, :admin)
      user = create(:user)
      create(:user_limit_override, user: user, key: 'ai_jobs_per_day', value: { 'value' => 150 })
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      expect {
        patch admin_system_setting_path('limits.max_ai_per_day'),
              params: {
                value: '100',
                reason: 'lower AI safety limit',
                confirm: '1'
              }
      }.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(admin_system_setting_path('limits.max_ai_per_day'))
        expect(flash[:alert]).to include('UserLimitsのシステム上限を超えています')
        expect(SystemSetting.find_by(key: 'limits.max_ai_per_day')).to be_nil
        expect(AuditLog.last).to have_attributes(
          action: 'system_settings.update',
          outcome: 'failed',
          error_code: 'user_limit_safety_max'
        )
      end
    end

    it 'お知らせ本文を更新でき、admin表示ではHTMLとして実行しない' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      patch admin_system_setting_path('ui.maintenance_notice_body'),
            params: {
              value: "<script>alert('x')</script>\n本文",
              reason: 'announcement copy update'
            }

      setting = SystemSetting.find_by!(key: 'ui.maintenance_notice_body')

      get admin_system_setting_path('ui.maintenance_notice_body')

      aggregate_failures do
        expect(setting.value).to eq('value' => "<script>alert('x')</script>\n本文")
        expect(response.body).to include('&lt;script&gt;alert')
        expect(response.body).not_to include("<script>alert('x')</script>")
      end
    end

    it 'maintenance notice setting update is reflected in the general layout' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      patch admin_system_setting_path('ui.maintenance_notice_enabled'),
            params: {
              value: 'true',
              reason: 'maintenance announcement'
            }

      get settings_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('shared.maintenance_notice.title'))
        expect(response.body).to include(I18n.t('shared.maintenance_notice.body'))
      end
    end

    it 'login_restricted中でもadminはmaintenance.modeをoffへ戻せる' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)
      create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))

      patch admin_system_setting_path('maintenance.mode'),
            params: {
              value: 'off',
              reason: 'maintenance finished',
              confirm: '1'
            }

      setting = SystemSetting.find_by!(key: 'maintenance.mode')

      aggregate_failures do
        expect(response).to redirect_to(admin_system_setting_path('maintenance.mode'))
        expect(flash[:notice]).to include('設定を更新しました')
        expect(setting.value).to eq('value' => 'off')
      end
    end

    it '存在しないkeyは404にする' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      patch admin_system_setting_path('secret.provider_api_key'),
            params: {
              value: 'secret',
              reason: 'bad key'
            }

      expect(response).to have_http_status(:not_found)
    end
  end
end
