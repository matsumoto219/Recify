require 'rails_helper'
require 'webauthn/fake_client'

RSpec.describe 'Admin receipt analysis runs', type: :request do
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

  def expect_no_analysis_jobs_enqueued
    analysis_jobs = [ ReceiptOcrJob, ReceiptAiEnrichmentJob, ReceiptFinalizeJob ]

    expect(enqueued_jobs.select { |job| analysis_jobs.include?(job[:job]) }).to be_empty
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

  describe 'GET /admin/receipt_analysis_runs' do
    it '非ログインユーザーはログインへリダイレクトする' do
      get admin_receipt_analysis_runs_path

      expect(response).to redirect_to(new_user_session_path)
    end

    it '一般ユーザーには既存404と同じbody/headerを返す' do
      user = create(:user)
      sign_in user

      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      sign_in user
      get admin_receipt_analysis_runs_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).to include(I18n.t('errors.not_found.title'))
        expect(response.body).not_to include('解析run管理')
        expect(response.body).not_to include('管理トップ')
        expect(response.body).not_to include('通常画面へ戻る')
        expect(response.body).not_to include('Admin::')
      end
    end

    it 'adminユーザーはindexを閲覧できる' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded)
      sign_in admin

      get admin_receipt_analysis_runs_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('解析run管理')
        expect(response.body).to include('管理トップ')
        expect(response.body).to include('通常画面へ戻る')
        expect(response.body).to include(run.run_key)
        expect(response.body).to include(run.receipt.display_id)
      end
    end

    it 'adminユーザーにはfilter formを表示する' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_receipt_analysis_runs_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('Filters')
        expect(response.body).to include('name="status"')
        expect(response.body).to include('name="stage"')
        expect(response.body).to include('name="source"')
        expect(response.body).to include('name="receipt_status"')
        expect(response.body).to include('name="needs_attention"')
        expect(response.body).to include('name="error_code"')
        expect(response.body).to include('name="run_key"')
        expect(response.body).to include('name="receipt_public_id"')
        expect(response.body).to include('name="user_id"')
      end
    end

    it 'filter paramsをAdmin queryへ渡す' do
      admin = create(:user, :admin)
      sign_in admin
      allow(Admin).to receive(:receipt_analysis_runs).and_call_original

      get admin_receipt_analysis_runs_path,
          params: {
            status: 'failed',
            stage: 'completed',
            source: 'upload',
            receipt_status: 'failed',
            error_code: 'ocr_unreadable',
            receipt_public_id: 'rcpt_filter',
            run_key: 'run-filter',
            user_id: '123',
            needs_attention: '1',
            limit: '10',
            offset: '20'
          }

      expect(Admin).to have_received(:receipt_analysis_runs).with(
        status: 'failed',
        stage: 'completed',
        source: 'upload',
        receipt_status: 'failed',
        error_code: 'ocr_unreadable',
        receipt_public_id: 'rcpt_filter',
        run_key: 'run-filter',
        user_id: '123',
        needs_attention: '1',
        limit: '10',
        offset: '20'
      )
    end

    it '空filter paramsはAdmin queryへ渡さない' do
      admin = create(:user, :admin)
      sign_in admin
      allow(Admin).to receive(:receipt_analysis_runs).and_call_original

      get admin_receipt_analysis_runs_path,
          params: {
            status: '',
            stage: '',
            source: '',
            receipt_status: '',
            error_code: '',
            run_key: '',
            receipt_public_id: '',
            user_id: ''
          }

      expect(Admin).to have_received(:receipt_analysis_runs).with(no_args)
    end

    it 'paginationのnext/prevがfilter paramsを維持する' do
      admin = create(:user, :admin)
      sign_in admin
      create_list(:receipt_analysis_run, 3, :failed, source: 'upload', final_result_summary: { receipt_status: 'failed' })

      get admin_receipt_analysis_runs_path,
          params: {
            status: 'failed',
            stage: 'completed',
            source: 'upload',
            receipt_status: 'failed',
            needs_attention: '1',
            limit: '1',
            offset: '1'
          }

      document = Nokogiri::HTML(response.body)
      previous_href = document.css('a').find { |link| link.text.strip == '前へ' }['href']
      next_href = document.css('a').find { |link| link.text.strip == '次へ' }['href']
      previous_query = Rack::Utils.parse_nested_query(URI.parse(previous_href).query)
      next_query = Rack::Utils.parse_nested_query(URI.parse(next_href).query)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('3件中 2-2件を表示')
        expect(previous_query).to include(
          'status' => 'failed',
          'stage' => 'completed',
          'source' => 'upload',
          'receipt_status' => 'failed',
          'needs_attention' => '1',
          'limit' => '1',
          'offset' => '0'
        )
        expect(next_query).to include(
          'status' => 'failed',
          'stage' => 'completed',
          'source' => 'upload',
          'receipt_status' => 'failed',
          'needs_attention' => '1',
          'limit' => '1',
          'offset' => '2'
        )
      end
    end
  end

  describe 'GET /admin/receipt_analysis_runs/:run_key' do
    it 'adminユーザーはshowを閲覧できる' do
      admin = create(:user, :admin)
      run = create(
        :receipt_analysis_run,
        :succeeded,
        ocr_summary: { schema_version: 'test', line_count: 3 },
        ai_input_snapshot: { filtered_content: 'safe content' },
        ai_result_summary: { success: true },
        final_result_summary: { receipt_status: 'completed' }
      )
      sign_in admin

      get admin_receipt_analysis_run_path(run.run_key)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('解析run詳細')
        expect(response.body).to include(run.run_key)
        expect(response.body).to include(run.receipt.display_id)
        expect(response.body).to include('Retry options')
        expect(response.body).to include('Snapshot presence')
        expect(response.body).to include('Finalize decision')
        expect(response.body).to include('Amount calculation profile')
        expect(response.body).to include('development/test では retry を実行できます')
        expect(response.body).to include('safe content')
        expect(response.body).not_to include('Analysis::RetryService.call')
      end
    end

    it '存在しないrun_keyは既存404へ流す' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_receipt_analysis_run_path('missing-run-key')

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to include(I18n.t('errors.not_found.title'))
      end
    end

    it 'raw/prompt/raw AI/secret系を表示しない' do
      admin = create(:user, :admin)
      run = create(
        :receipt_analysis_run,
        :succeeded,
        ocr_summary: {
          raw_response: 'RAW OCR RESPONSE',
          nested: { secret_token: 'SECRET', line_count: 3 }
        },
        ai_input_snapshot: {
          prompt: 'FULL PROMPT',
          filtered_content: 'safe content'
        },
        ai_result_summary: {
          response_body: 'RAW AI RESPONSE',
          success: true
        },
        final_result_summary: {
          receipt_status: 'completed',
          signed_id: 'SIGNED'
        }
      )
      sign_in admin

      get admin_receipt_analysis_run_path(run.run_key)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('safe content')
        expect(response.body).to include('line_count')
        expect(response.body).not_to include('RAW OCR RESPONSE')
        expect(response.body).not_to include('FULL PROMPT')
        expect(response.body).not_to include('RAW AI RESPONSE')
        expect(response.body).not_to include('SECRET')
        expect(response.body).not_to include('SIGNED')
      end
    end

    it 'production相当ではretry form/buttonを表示しない' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded)
      sign_in admin
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))

      get admin_receipt_analysis_run_path(run.run_key)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('production retry action requires fresh passkey reauthentication')
        expect(response.body).to include(new_admin_passkey_reauthentication_path)
        expect(response.body).not_to include('name="retry_type"')
        expect(response.body).not_to include('再解析理由')
        expect(response.body).not_to include('value="Retry"')
      end
    end

    it 'production相当でfresh reauth済みならretry form/buttonを表示する' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded, receipt: create(:receipt, :completed, :with_image))
      sign_in admin
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))
      reauthenticate_admin_with_passkey!(admin)

      get admin_receipt_analysis_run_path(run.run_key)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('fresh passkey reauthentication is active')
        expect(response.body).to include('name="retry_type"')
        expect(response.body).to include('再解析理由')
        expect(response.body).to include('value="Retry"')
      end
    end
  end

  describe 'POST /admin/receipt_analysis_runs/:run_key/retry' do
    it 'development/testではRetryService経由でretryし、request contextを渡す' do
      admin = create(:user, :admin)
      parent_run = create(:receipt_analysis_run, :succeeded, receipt: create(:receipt, :completed, :with_image))
      new_run = create(:receipt_analysis_run, receipt: parent_run.receipt, parent_run: parent_run)
      result = Analysis::RetryService::Result.new(
        run: new_run,
        enqueued_job: ReceiptOcrJob,
        retry_type: 'full_reanalyze'
      )
      sign_in admin
      allow(Analysis::RetryService).to receive(:call).and_return(result)

      post retry_admin_receipt_analysis_run_path(parent_run.run_key),
           params: {
             retry_type: 'full_reanalyze',
             reason: '問い合わせ対応'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_run_path(new_run.run_key))
        expect(flash[:notice]).to include('Retry enqueued')
        expect(Analysis::RetryService).to have_received(:call).with(
          receipt: parent_run.receipt,
          parent_run: parent_run,
          actor: admin,
          retry_type: 'full_reanalyze',
          reason: '問い合わせ対応',
          request: kind_of(ActionDispatch::Request)
        )
        expect_no_analysis_jobs_enqueued
      end
    end

    it 'RetryServiceが失敗した場合は元runへredirectしてalertを出す' do
      admin = create(:user, :admin)
      parent_run = create(:receipt_analysis_run, :succeeded)
      result = Analysis::RetryService::Result.new(
        run: nil,
        enqueued_job: nil,
        retry_type: 'ai_retry',
        error_code: 'ocr_snapshot_missing',
        error_message: 'parent_run.ocr_result_snapshot is required'
      )
      sign_in admin
      allow(Analysis::RetryService).to receive(:call).and_return(result)

      post retry_admin_receipt_analysis_run_path(parent_run.run_key),
           params: {
             retry_type: 'ai_retry',
             reason: 'AIだけ再実行'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_run_path(parent_run.run_key))
        expect(flash[:alert]).to include('ocr_snapshot_missing')
        expect(Analysis::RetryService).to have_received(:call)
        expect_no_analysis_jobs_enqueued
      end
    end

    it 'reason blank はRetryServiceを呼ばずに拒否する' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded)
      sign_in admin
      allow(Analysis::RetryService).to receive(:call)

      post retry_admin_receipt_analysis_run_path(run.run_key),
           params: {
             retry_type: 'full_reanalyze',
             reason: ''
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_run_path(run.run_key))
        expect(flash[:alert]).to include('reason is required')
        expect(Analysis::RetryService).not_to have_received(:call)
        expect_no_analysis_jobs_enqueued
      end
    end

    it 'invalid retry_type はRetryServiceを呼ばずに拒否する' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded)
      sign_in admin
      allow(Analysis::RetryService).to receive(:call)

      post retry_admin_receipt_analysis_run_path(run.run_key),
           params: {
             retry_type: 'destroy_everything',
             reason: 'invalid'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_run_path(run.run_key))
        expect(flash[:alert]).to include('Invalid retry type')
        expect(Analysis::RetryService).not_to have_received(:call)
        expect_no_analysis_jobs_enqueued
      end
    end

    it 'production相当でfresh reauthなしならRetryServiceを呼ばずreauthへredirectする' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded)
      sign_in admin
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))
      allow(Analysis::RetryService).to receive(:call)

      post retry_admin_receipt_analysis_run_path(run.run_key),
           params: {
             retry_type: 'full_reanalyze',
             reason: 'production disabled'
           }

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_receipt_analysis_run_path(run.run_key)))
        expect(flash[:alert]).to include('fresh passkey reauthentication')
        expect(Analysis::RetryService).not_to have_received(:call)
        expect(session.to_hash.to_json).not_to include('production disabled', 'full_reanalyze')
        expect_no_analysis_jobs_enqueued
      end
    end

    it 'production相当でpasskey未登録adminもRetryServiceを呼ばずreauthへredirectする' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded)
      sign_in admin
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))
      allow(Analysis::RetryService).to receive(:call)

      post retry_admin_receipt_analysis_run_path(run.run_key),
           params: {
             retry_type: 'full_reanalyze',
             reason: 'passkey missing'
           }

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_receipt_analysis_run_path(run.run_key)))
        expect(Analysis::RetryService).not_to have_received(:call)
        expect_no_analysis_jobs_enqueued
      end
    end

    it 'production相当でfresh reauth済みならRetryServiceへreauthentication metadataを渡す' do
      admin = create(:user, :admin)
      parent_run = create(:receipt_analysis_run, :succeeded, receipt: create(:receipt, :completed, :with_image))
      new_run = create(:receipt_analysis_run, receipt: parent_run.receipt, parent_run: parent_run)
      result = Analysis::RetryService::Result.new(
        run: new_run,
        enqueued_job: ReceiptOcrJob,
        retry_type: 'full_reanalyze'
      )
      sign_in admin
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))
      reauthenticate_admin_with_passkey!(admin)
      allow(Analysis::RetryService).to receive(:call).and_return(result)

      post retry_admin_receipt_analysis_run_path(parent_run.run_key),
           params: {
             retry_type: 'full_reanalyze',
             reason: 'production fresh retry'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_run_path(new_run.run_key))
        expect(Analysis::RetryService).to have_received(:call).with(
          receipt: parent_run.receipt,
          parent_run: parent_run,
          actor: admin,
          retry_type: 'full_reanalyze',
          reason: 'production fresh retry',
          request: kind_of(ActionDispatch::Request),
          reauthentication: hash_including(
            method: 'passkey',
            reauthenticated_at: kind_of(Time)
          )
        )
        expect_no_analysis_jobs_enqueued
      end
    end

    it '非admin404方針を維持する' do
      user = create(:user)
      run = create(:receipt_analysis_run, :succeeded)
      sign_in user

      post retry_admin_receipt_analysis_run_path(run.run_key),
           params: {
             retry_type: 'full_reanalyze',
             reason: 'not admin'
           }

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.body).to include(I18n.t('errors.not_found.title'))
      end
    end

    it '実RetryService経由でAuditLogへrequest contextを保存する' do
      admin = create(:user, :admin)
      parent_run = create(:receipt_analysis_run, :succeeded, receipt: create(:receipt, :completed, :with_image))
      sign_in admin

      expect do
        post retry_admin_receipt_analysis_run_path(parent_run.run_key),
             params: {
               retry_type: 'full_reanalyze',
               reason: '監査ログ確認'
             },
             headers: {
               'HTTP_USER_AGENT' => 'Admin Retry Spec'
             }
      end.to change(AuditLog, :count).by(1)

      audit_log = AuditLog.last

      aggregate_failures do
        expect(response).to have_http_status(:redirect)
        expect(audit_log).to have_attributes(
          actor_user: admin,
          action: 'receipt_analysis.full_reanalyze',
          outcome: 'succeeded',
          target_uid: parent_run.receipt.public_id,
          reason: '監査ログ確認'
        )
        expect(audit_log.request_id).to be_present
        expect(audit_log.user_agent).to eq('Admin Retry Spec')
        expect(audit_log.ip_address).to be_present
      end
    end
  end

  it 'GETでは解析Jobをenqueueしない' do
    admin = create(:user, :admin)
    run = create(:receipt_analysis_run, :succeeded)
    sign_in admin

    get admin_receipt_analysis_runs_path
    get admin_receipt_analysis_run_path(run.run_key)

    expect_no_analysis_jobs_enqueued
  end
end
