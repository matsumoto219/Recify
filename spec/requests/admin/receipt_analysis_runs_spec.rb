require 'rails_helper'

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
        expect(response.body).not_to include('解析run管理')
        expect(response.body).not_to include('Admin::')
      end
    end

    it 'adminユーザーはindexを閲覧できる' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded)
      sign_in admin

      get admin_root_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('解析run管理')
        expect(response.body).to include(run.run_key)
        expect(response.body).to include(run.receipt.display_id)
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
        needs_attention: '1',
        limit: '10',
        offset: '20'
      )
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
        expect(response.body).to include('safe content')
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
