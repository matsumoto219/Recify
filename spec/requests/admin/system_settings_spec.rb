require 'rails_helper'
require 'webauthn/fake_client'

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
        expect(response.body).not_to include('設定を更新')
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
