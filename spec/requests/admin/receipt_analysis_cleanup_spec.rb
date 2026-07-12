require 'rails_helper'
require 'webauthn/fake_client'

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

  describe 'GET /admin/receipt_analysis_cleanup' do
    it '文字が混在するlimitを別の件数へ変換せず入力値付きで再表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_receipt_analysis_cleanup_path, params: { stale_limit: '12abc' }

      document = Nokogiri::HTML(response.body)
      input = document.at_css('input[name="stale_limit"]')

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(input['value']).to eq('12abc')
        expect(input['inputmode']).to eq('numeric')
        expect(document.at_css('input[name="retention_limit"]')['inputmode']).to eq('numeric')
        expect(response.body).to include(I18n.t('admin.receipt_analysis_cleanup.messages.invalid_limit'))
      end
    end
    it '非ログインユーザーには既存404と同じbody/headerを返す' do
      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      get admin_receipt_analysis_cleanup_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.location).to be_nil
        expect(response.body).not_to include('Cleanup確認')
      end
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
        expect(response.body).not_to include('Cleanup確認')
      end
    end

    it 'adminユーザーはcleanup確認画面を閲覧できる' do
      admin = create(:user, :admin)
      stale_run = create_stale_run
      expired_run = create(:receipt_analysis_run, :succeeded, expires_at: 1.day.ago)
      sign_in admin

      get admin_receipt_analysis_cleanup_path

      document = Nokogiri::HTML(response.body)
      tables = document.css('table')
      run_key_cells = document.css('td').select { |cell| cell.text.include?(stale_run.run_key) || cell.text.include?(expired_run.run_key) }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('Cleanup確認')
        expect(response.body).to include('解析run管理')
        expect(response.body).to include('監査ログ')
        expect(response.body).to include('Stale active runs')
        expect(response.body).to include('Expired terminal runs')
        expect(response.body).to include('パスキー再認証')
        expect(response.body).to include('stale_count')
        expect(response.body).to include('expired_count')
        expect(response.body).to include(stale_run.run_key)
        expect(response.body).to include(expired_run.run_key)
        expect(response.body).to include(admin_receipt_analysis_run_path(stale_run.run_key))
        expect(response.body).to include(admin_receipt_analysis_run_path(expired_run.run_key))
        expect(response.body).to include('Cleanup実行は重要な管理操作です')
        expect(tables.size).to eq(2)
        expect(tables.all? { |table| table['class'].include?('min-w-[56rem]') }).to be(true)
        expect(run_key_cells.size).to eq(2)
        expect(run_key_cells.all? { |cell| cell['class'].include?('min-w-[18rem]') }).to be(true)
        expect(run_key_cells.all? { |cell| cell['class'].include?('whitespace-nowrap') }).to be(true)
      end
    end

    it 'paramsで実行指定を渡してもGETでは実更新/削除しない' do
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

    it '空状態は横スクロールtable内ではなく折り返し可能なブロックで表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_receipt_analysis_cleanup_path

      empty_state_class = 'max-w-full rounded-lg border token-border-soft token-bg-card-subtle px-4 py-8 text-center text-sm token-text-muted break-words [overflow-wrap:anywhere]'

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('admin.receipt_analysis_cleanup.stale.empty'))
        expect(response.body).to include(I18n.t('admin.receipt_analysis_cleanup.retention.empty'))
        expect(response.body).to include(empty_state_class)
        expect(response.body).not_to include('colspan="5"')
        expect(response.body).not_to include('colspan="4"')
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

    it 'fresh reauth済みなら実行フォームを表示する' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      get admin_receipt_analysis_cleanup_path

      document = Nokogiri::HTML(response.body)
      textareas = document.css('textarea[name="reason"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('Stale cleanupを実行')
        expect(response.body).to include('Retention cleanupを実行')
        expect(response.body).to include('name="reason"')
        expect(response.body).to include('name="confirm"')
        expect(response.body).to include('DELETE EXPIRED RUNS')
        expect(textareas.size).to eq(2)
        expect(textareas.all? { |textarea| textarea['class'].include?('py-2') }).to be(true)
        expect(textareas.all? { |textarea| textarea['class'].include?('leading-6') }).to be(true)
      end
    end
  end

  describe 'POST /admin/receipt_analysis_cleanup/stale' do
    it 'fresh reauthなしではSystemOperationsを呼ばずreauthへredirectする' do
      admin = create(:user, :admin)
      sign_in admin
      allow(SystemOperations).to receive(:execute_receipt_analysis_cleanup)

      post admin_receipt_analysis_cleanup_stale_path,
           params: {
             stale_cutoff: '2026-05-23T03:00',
             stale_limit: '10',
             reason: 'clear stale runs',
             confirm: '1'
           }

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_receipt_analysis_cleanup_path))
        expect(SystemOperations).not_to have_received(:execute_receipt_analysis_cleanup)
        expect(session.to_hash.to_json).not_to include('clear stale runs')
        expect_no_cleanup_or_analysis_jobs
      end
    end

    it 'reason blankでは実行しない' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)
      allow(SystemOperations).to receive(:execute_receipt_analysis_cleanup)

      post admin_receipt_analysis_cleanup_stale_path,
           params: {
             stale_cutoff: '2026-05-23T03:00',
             stale_limit: '10',
             reason: ' ',
             confirm: '1'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_cleanup_path(stale_cutoff: '2026-05-23T03:00', stale_limit: '10'))
        expect(flash[:alert]).to include('実行理由')
        expect(SystemOperations).not_to have_received(:execute_receipt_analysis_cleanup)
      end
    end

    it 'confirmationなしでは実行しない' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)
      allow(SystemOperations).to receive(:execute_receipt_analysis_cleanup)

      post admin_receipt_analysis_cleanup_stale_path,
           params: {
             stale_cutoff: '2026-05-23T03:00',
             stale_limit: '10',
             reason: 'clear stale runs'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_cleanup_path(stale_cutoff: '2026-05-23T03:00', stale_limit: '10'))
        expect(flash[:alert]).to include('実行確認')
        expect(SystemOperations).not_to have_received(:execute_receipt_analysis_cleanup)
      end
    end

    it 'fresh reauth + reason + confirmationでSystemOperations経由で実行する' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)
      result = SystemOperations::Result.new(
        success: true,
        cleanup_result: {
          failed_count: 1,
          canceled_count: 0
        }
      )
      allow(SystemOperations).to receive(:execute_receipt_analysis_cleanup).and_return(result)
      allow(Receipts::Processing).to receive(:cleanup_stale)

      post admin_receipt_analysis_cleanup_stale_path,
           params: {
             stale_cutoff: '2026-05-23T03:00',
             stale_limit: '10',
             reason: 'clear stale runs',
             confirm: '1'
           },
           headers: { 'HTTP_USER_AGENT' => 'Cleanup Request Spec' }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_cleanup_path(stale_cutoff: '2026-05-23T03:00', stale_limit: '10'))
        expect(flash[:notice]).to include('Stale cleanupを実行しました')
        expect(SystemOperations).to have_received(:execute_receipt_analysis_cleanup).with(
          operation: 'stale_cleanup',
          actor: admin,
          reason: 'clear stale runs',
          cutoff: '2026-05-23T03:00',
          limit: '10',
          request: kind_of(ActionDispatch::Request),
          reauthentication: hash_including(
            method: 'passkey',
            reauthenticated_at: kind_of(Time)
          )
        )
        expect(Receipts::Processing).not_to have_received(:cleanup_stale)
        expect_no_cleanup_or_analysis_jobs
      end
    end

    it '実行結果をAuditLogに残し、stale active runをterminal化する' do
      admin = create(:user, :admin)
      stale_run = create_stale_run
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)
      audit_count = AuditLog.count

      post admin_receipt_analysis_cleanup_stale_path,
           params: {
             stale_cutoff: '2026-05-23T04:00',
             stale_limit: '10',
             reason: 'actual stale cleanup',
             confirm: '1'
           },
           headers: { 'HTTP_USER_AGENT' => 'Cleanup Request Spec' }

      audit_log = AuditLog
        .where(action: 'receipt_analysis_runs.cleanup_stale.execute', reason: 'actual stale cleanup')
        .order(:created_at, :id)
        .last

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_cleanup_path(stale_cutoff: '2026-05-23T04:00', stale_limit: '10'))
        expect(stale_run.reload.status).to eq('failed')
        expect(stale_run.receipt.reload.status).to eq('failed')
        expect(AuditLog.count).to eq(audit_count + 1)
        expect(audit_log).to be_present
        expect(audit_log).to have_attributes(
          actor_user: admin,
          action: 'receipt_analysis_runs.cleanup_stale.execute',
          outcome: 'succeeded',
          reason: 'actual stale cleanup',
          user_agent: 'Cleanup Request Spec'
        )
        expect(audit_log.metadata).to include(
          'dry_run' => false,
          'stale_count' => 1,
          'failed_count' => 1,
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey'
        )
        expect(audit_log.metadata.fetch('sample_run_keys')).to include(stale_run.run_key)
        expect(audit_log.metadata.to_json).not_to include('credential_id', 'challenge', 'public_key')
      end
    end
  end

  describe 'POST /admin/receipt_analysis_cleanup/retention' do
    it 'fresh reauth + reason + confirmation textでSystemOperations経由で実行する' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)
      result = SystemOperations::Result.new(
        success: true,
        cleanup_result: {
          deleted_count: 2
        }
      )
      allow(SystemOperations).to receive(:execute_receipt_analysis_cleanup).and_return(result)

      post admin_receipt_analysis_cleanup_retention_path,
           params: {
             retention_cutoff: '2026-05-23T09:00',
             retention_limit: '20',
             reason: 'delete expired runs',
             confirm: '1',
             confirmation_text: 'DELETE EXPIRED RUNS'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_cleanup_path(retention_cutoff: '2026-05-23T09:00', retention_limit: '20'))
        expect(flash[:notice]).to include('Retention cleanupを実行しました')
        expect(SystemOperations).to have_received(:execute_receipt_analysis_cleanup).with(
          operation: 'retention_cleanup',
          actor: admin,
          reason: 'delete expired runs',
          cutoff: '2026-05-23T09:00',
          limit: '20',
          request: kind_of(ActionDispatch::Request),
          reauthentication: hash_including(method: 'passkey')
        )
        expect_no_cleanup_or_analysis_jobs
      end
    end

    it 'confirmation textが一致しない場合は実行しない' do
      admin = create(:user, :admin)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)
      allow(SystemOperations).to receive(:execute_receipt_analysis_cleanup)

      post admin_receipt_analysis_cleanup_retention_path,
           params: {
             retention_cutoff: '2026-05-23T09:00',
             retention_limit: '20',
             reason: 'delete expired runs',
             confirm: '1',
             confirmation_text: 'wrong'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_cleanup_path(retention_cutoff: '2026-05-23T09:00', retention_limit: '20'))
        expect(flash[:alert]).to include('実行確認')
        expect(SystemOperations).not_to have_received(:execute_receipt_analysis_cleanup)
      end
    end
  end

  def create_stale_run
    receipt = create(:receipt, :with_image, :processing)
    run = create(:receipt_analysis_run, receipt: receipt, status: 'queued', stage: 'queued')
    run.update_columns(updated_at: 7.hours.ago)
    run
  end
end
