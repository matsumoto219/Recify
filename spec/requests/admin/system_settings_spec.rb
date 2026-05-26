require 'rails_helper'

RSpec.describe 'Admin system settings', type: :request do
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
    expect(SystemOperations).not_to respond_to(:update_setting)
  end

  describe 'GET /admin/system_settings' do
    it '非ログインユーザーはログインへリダイレクトする' do
      get admin_system_settings_path

      expect(response).to redirect_to(new_user_session_path)
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
        expect(response.body).not_to include('System settings')
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
        expect(response.body).to include('System settings')
        expect(response.body).to include('Definition allowlist')
        expect(response.body).to include('feature.receipt_logo_display_enabled')
        expect(response.body).to include('limits.receipt_upload_soft_limit')
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
        expect_no_side_effects
      end
    end
  end

  describe 'GET /admin/system_settings/:key' do
    it 'adminユーザーはdot入りkeyの詳細を閲覧できる' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('limits.receipt_upload_soft_limit')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('limits.receipt_upload_soft_limit')
        expect(response.body).to include('soft_limit')
        expect(response.body).to include('100')
        expect(response.body).to include(admin_audit_logs_path(target_uid: 'limits.receipt_upload_soft_limit'))
        expect(response.body).not_to include('SENTRY_DSN')
        expect(response.body).not_to include('WEBAUTHN_RP_ID')
        expect(response.body).not_to include('name="reason"')
        expect_no_side_effects
      end
    end

    it '存在しないkeyは404にする' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_system_setting_path('secret.provider_api_key')

      expect(response).to have_http_status(:not_found)
    end
  end

  it 'write routeを提供しない' do
    admin = create(:user, :admin)
    sign_in admin

    post admin_system_settings_path
    expect(response).to have_http_status(:not_found)

    patch admin_system_setting_path('feature.receipt_logo_display_enabled')
    expect(response).to have_http_status(:not_found)
  end
end
