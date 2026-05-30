require 'rails_helper'

RSpec.describe 'Admin audit logs', type: :request do
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

  def expect_no_admin_side_effects
    analysis_jobs = [ ReceiptOcrJob, ReceiptAiEnrichmentJob, ReceiptFinalizeJob ]

    expect(enqueued_jobs.select { |job| analysis_jobs.include?(job[:job]) }).to be_empty
    expect(Analysis::RetryService).not_to have_received(:call)
  end

  describe 'GET /admin/audit_logs' do
    it '非ログインユーザーには既存404と同じbody/headerを返す' do
      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      get admin_audit_logs_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.location).to be_nil
        expect(response.body).not_to include('監査ログ')
      end
    end

    it '一般ユーザーには既存404と同じbody/headerを返す' do
      user = create(:user)
      sign_in user

      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      sign_in user
      get admin_audit_logs_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).to include(I18n.t('errors.not_found.title'))
        expect(response.body).not_to include('監査ログ')
      end
    end

    it 'adminユーザーはindexを閲覧でき、navigationに監査ログが出る' do
      admin = create(:user, :admin)
      log = create(:audit_log, action: 'receipt_analysis.full_reanalyze', target_uid: 'rcpt_index')
      sign_in admin

      get admin_audit_logs_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('監査ログ')
        expect(response.body).to include('解析run管理')
        expect(response.body).to include('通常画面へ戻る')
        expect(response.body).to include(log.action)
        expect(response.body).to include('rcpt_index')
      end
    end

    it 'filter paramsをAdmin queryへ渡す' do
      admin = create(:user, :admin)
      sign_in admin
      allow(Admin).to receive(:audit_logs).and_call_original

      get admin_audit_logs_path,
          params: {
            actor_user_id: '1',
            actor_kind: 'admin',
            audit_action: 'receipt_analysis.ai_retry',
            outcome: 'failed',
            target_uid: 'rcpt_filter',
            request_id: 'req-filter',
            error_code: 'ocr_snapshot_missing',
            created_from: '2026-05-01T00:00',
            created_to: '2026-05-26T23:59',
            limit: '10',
            offset: '20'
          }

      expect(Admin).to have_received(:audit_logs).with(
        actor_user_id: '1',
        actor_kind: 'admin',
        action: 'receipt_analysis.ai_retry',
        outcome: 'failed',
        target_uid: 'rcpt_filter',
        request_id: 'req-filter',
        error_code: 'ocr_snapshot_missing',
        created_from: '2026-05-01T00:00',
        created_to: '2026-05-26T23:59',
        limit: '10',
        offset: '20'
      )
    end

    it 'paginationのnext/prevがfilter paramsを維持する' do
      admin = create(:user, :admin)
      sign_in admin
      create_list(:audit_log, 3, outcome: 'failed', action: 'receipt_analysis.ai_retry')

      get admin_audit_logs_path,
          params: {
            outcome: 'failed',
            audit_action: 'receipt_analysis.ai_retry',
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
          'outcome' => 'failed',
          'audit_action' => 'receipt_analysis.ai_retry',
          'limit' => '1',
          'offset' => '0'
        )
        expect(next_query).to include(
          'outcome' => 'failed',
          'audit_action' => 'receipt_analysis.ai_retry',
          'limit' => '1',
          'offset' => '2'
        )
      end
    end
  end

  describe 'GET /admin/audit_logs/:id' do
    it 'adminユーザーはshowを閲覧できる' do
      admin = create(:user, :admin)
      log = create(
        :audit_log,
        action: 'receipt_analysis.finalize_retry',
        target_uid: 'rcpt_show',
        metadata: {
          parent_run_key: 'parent-run',
          new_run_key: 'new-run',
          enqueued_job: 'ReceiptFinalizeJob'
        }
      )
      sign_in admin

      get admin_audit_log_path(log)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('監査ログ詳細')
        expect(response.body).to include('receipt_analysis.finalize_retry')
        expect(response.body).to include('rcpt_show')
        expect(response.body).to include('parent-run')
        expect(response.body).to include('new-run')
        expect(response.body).to include('ReceiptFinalizeJob')
      end
    end

    it '存在しないidは既存404へ流す' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_audit_log_path(999_999)

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to include(I18n.t('errors.not_found.title'))
      end
    end

    it 'metadata/before/afterのraw/prompt/secret系を表示しない' do
      admin = create(:user, :admin)
      log = create(
        :audit_log,
        metadata: {
          safe: 'visible',
          raw_text: 'RAW OCR',
          prompt: 'FULL PROMPT',
          nested: {
            secret_token: 'SECRET',
            kept: 'ok'
          }
        },
        before_state: {
          password: 'PASSWORD',
          status: 'failed'
        },
        after_state: {
          response_body: 'RAW AI',
          status: 'processing'
        }
      )
      sign_in admin

      get admin_audit_log_path(log)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('visible')
        expect(response.body).to include('ok')
        expect(response.body).to include('failed')
        expect(response.body).to include('processing')
        expect(response.body).not_to include('RAW OCR')
        expect(response.body).not_to include('FULL PROMPT')
        expect(response.body).not_to include('SECRET')
        expect(response.body).not_to include('PASSWORD')
        expect(response.body).not_to include('RAW AI')
      end
    end
  end

  it 'GETではJob enqueue / RetryService callを発生させない' do
    admin = create(:user, :admin)
    log = create(:audit_log)
    sign_in admin
    allow(Analysis::RetryService).to receive(:call)

    get admin_audit_logs_path
    get admin_audit_log_path(log)

    expect_no_admin_side_effects
  end

  it '編集/削除routeを作らない' do
    patch "/admin/audit_logs/1"
    expect(response).to have_http_status(:not_found)

    delete "/admin/audit_logs/1"
    expect(response).to have_http_status(:not_found)
  end
end
