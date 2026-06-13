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
    it '非ログインユーザーには既存404と同じbody/headerを返す' do
      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      get admin_receipt_analysis_runs_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.location).to be_nil
        expect(response.body).to include(I18n.t('errors.not_found.title'))
        expect(response.body).not_to include('解析run管理')
        expect(response.body).not_to include('管理トップ')
      end
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
        expect(response.body).to include(I18n.t('admin.receipt_analysis_runs.index.filters.title', locale: :ja))
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
      receipt = create(
        :receipt,
        :completed,
        purchased_at: Time.zone.local(2026, 4, 19, 16, 41),
        review_reasons: [ 'purchased_at_uncertain' ]
      )
      receipt.update!(
        amount_calculation_profile: {
          'profile' => { 'tax_detail_amount_basis' => 'gross' },
          'warnings' => [ 'price_tax_inclusion_uncertain' ],
          'blocking_mismatch_codes' => [ 'ITEM_TOTAL_MISMATCH' ]
        }
      )
      run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_summary: {
          schema_version: 'test',
          line_count: 3,
          polling_metrics: {
            elapsed_ms: 3200,
            poll_count: 3,
            final_status: 'succeeded',
            max_poll_count: 20,
            poll_interval: 1.0,
            total_poll_sleep_ms: 5500,
            max_poll_interval: 3.0,
            poll_backoff_factor: 1.5,
            reached_max_poll: false,
            retry_after_used: true,
            retry_count: 1
          }
        },
        ocr_result_snapshot: {
          lines: [
            '2026年 4月19日(日)no2',
            '0796 16時41分'
          ],
          candidates: {
            purchased_at_text: '2026-04-19',
            purchased_at_candidates: [ '0796 16時41分' ],
            adjustment_candidates: [
              { source_text: 'Short Dated Stock Discount -2160', amount: 2160, sign_hint: 'discount' }
            ]
          },
          meta: { line_count: 2 }
        },
        ai_input_snapshot: {
          filtered_content: 'safe content',
          full_context_lines: [
            { index: 0, text: '0796 16時41分' },
            { index: 1, text: '10%対象 44 消費税 4' }
          ],
          purchase: {
            purchased_at_text: '2026-04-19',
            purchased_at_candidates: [ '0796 16時41分' ],
            purchase_context_lines: [ '領収書', '0796 16時41分' ]
          },
          tax: {
            tax_details: [ { rate: '0.10', net_amount: 44, amount: 4 } ],
            tax_context_lines: [ '10%対象 44 消費税 4' ]
          },
          items: [
            {
              index: 1,
              raw_text: 'アウトレット袋S',
              line_total: 44,
              tax_rate_candidate: '0.10',
              matched_content_lines: [ 'アウトレット袋S 44' ]
            }
          ]
        },
        ai_result_summary: {
          success: true,
          metrics: {
            provider: 'openai',
            model: 'gpt-test',
            elapsed_ms: 1200,
            retry_count: 2,
            retry_after_used: true,
            total_retry_sleep_ms: 4000,
            rate_limited: true,
            provider_status: '429',
            token_usage: {
              input_tokens: 100,
              output_tokens: 20,
              total_tokens: 120
            },
            response_id: 'resp_admin_metrics',
            fallback_used: true,
            fallback_provider: 'backup-provider',
            fallback_reason: 'ai_api_error',
            final_provider: 'backup-provider'
          }
        },
        ai_normalized_result_snapshot: {
          receipt_attributes: {
            purchased_at_text: '2026-04-19'
          },
          receipt_items_attributes: [],
          receipt_adjustments_attributes: [
            { kind: 'other', amount: 91, needs_review: true, review_reasons: [ 'adjustment_uncertain' ] }
          ]
        },
        final_result_summary: { receipt_status: 'completed' },
        metadata: {
          build_params_snapshot: {
            schema_version: 'receipt_analysis_run_build_params_v1',
            receipt_attributes: {
              purchased_at: '2026-04-19T16:41:00+09:00'
            },
            receipt_adjustments_count: 2,
            corrections: {
              purchased_at_fallback: {
                applied: true,
                source: 'ocr_time_candidate',
                date_text: '2026-04-19',
                time_text: '16時41分',
                ignored_prefix: '0796',
                result: '2026-04-19 16:41'
              },
              tax_rate_correction: {
                reason: 'tax_detail_amount_match',
                matches: [
                  { target: 'item', amount: 44, rate: '0.1' },
                  { target: 'adjustment', amount: 2160, rate: '0.08' }
                ]
              }
            },
            review_reasons: []
          }
        }
      )
      sign_in admin

      get admin_receipt_analysis_run_path(run.run_key)

      document = Nokogiri::HTML(response.body)
      analysis_sections = document.css('[data-admin-analysis-section]').map { |node| node['data-admin-analysis-section'] }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('解析run詳細')
        expect(response.body).to include(run.run_key)
        expect(response.body).to include(run.receipt.display_id)
        expect(response.body).to include('Retry options')
        expect(response.body).to include('Snapshot presence')
        expect(response.body).to include('ai_normalized_result_snapshot')
        expect(response.body).to include('min-w-0 max-w-full')
        expect(response.body).to include('max-w-full whitespace-pre rounded-lg token-bg-input token-border-soft border p-4 text-xs token-text-base overflow-x-auto')
        expect(response.body).to include('max-w-full whitespace-pre rounded-lg token-bg-input token-border-soft border p-4 text-xs token-text-base max-h-[32rem] overflow-auto')
        expect(response.body).to include('flex min-w-0 items-center justify-between gap-3')
        expect(response.body).to include('block min-w-0 break-words font-mono text-xs token-text-muted [overflow-wrap:anywhere]')
        expect(response.body).to include('mt-4 min-w-0 max-w-full rounded-lg border token-border-soft token-bg-card-subtle p-3')
        expect(response.body).to include('mt-3 grid min-w-0 max-w-full gap-3 text-sm md:grid-cols-2')
        expect(response.body).to include('min-w-0 break-words font-mono text-xs token-text-base [overflow-wrap:anywhere]')
        expect(response.body).to include('shrink-0 whitespace-nowrap token-text-success')
        expect(response.body).to include('shrink-0 whitespace-nowrap token-text-muted')
        expect(response.body).to include('Finalize decision')
        expect(response.body).to include('Amount calculation profile')
        expect(response.body).to include('再解析にはパスキー再認証が必要です')
        expect(response.body).to include(new_admin_passkey_reauthentication_path)
        expect(response.body).to include('safe content')
        expect(response.body).to include('OCR summary')
        expect(response.body).to include('OCR polling')
        expect(response.body).to include('OCR処理時間')
        expect(response.body).to include('3200ms')
        expect(response.body).to include('3 / 20')
        expect(response.body).to include('poll待機合計')
        expect(response.body).to include('5500ms')
        expect(response.body).to include('最大poll間隔')
        expect(response.body).to include('3.0s')
        expect(response.body).to include('poll backoff factor')
        expect(response.body).to include('1.5')
        expect(response.body).to include('Retry-After使用')
        expect(response.body).to include('AI metrics')
        expect(response.body).to include('AI処理時間')
        expect(response.body).to include('1200ms')
        expect(response.body).to include('retry待機合計')
        expect(response.body).to include('4000ms')
        expect(response.body).to include('rate limit')
        expect(response.body).to include('provider status')
        expect(response.body).to include('429')
        expect(response.body).to include('fallback reason')
        expect(response.body).to include('ai_api_error')
        expect(response.body).to include('response id')
        expect(response.body).to include('resp_admin_metrics')
        expect(response.body).to include('input: 100 / output: 20 / total: 120')
        expect(response.body).to include('AI input snapshot')
        expect(response.body).to include('AI result summary')
        expect(response.body).to include('Final result summary')
        expect(response.body).to include('AI input highlights')
        expect(response.body).to include('purchase_context_lines')
        expect(response.body).to include('領収書')
        expect(response.body).to include('tax_details')
        expect(response.body).to include('10%対象 44 消費税 4')
        expect(response.body).to include('adjustment_candidates')
        expect(response.body).to include('Short Dated Stock Discount -2160')
        expect(response.body).to include('full_context_lines')
        expect(response.body).to include('アウトレット袋S')
        expect(analysis_sections).to eq(%w[ocr ai build_params amount finalize])
        expect(response.body).to include('Correction summary')
        expect(response.body).to include('purchased_at fallback')
        expect(response.body).to include('applied')
        expect(response.body).to include('2026-04-19 16:41 / ocr_time_candidate')
        expect(response.body).to include('tax rate corrections')
        expect(response.body).to include('2 total / 1 uncertain')
        expect(response.body).to include('amount warnings')
        expect(response.body).to include('amount blocking')
        expect(response.body).to include('gross')
        expect(response.body).to include(I18n.l(receipt.purchased_at, format: :short))
        expect(response.body).to include('purchased_at_uncertain')
        expect(response.body).to include('OCR result snapshot')
        expect(response.body).to include('AI normalized result snapshot')
        expect(response.body).to include('BuildParams snapshot')
        expect(response.body).to include('2026年 4月19日(日)no2')
        expect(response.body).to include('0796 16時41分')
        expect(response.body).to include('purchased_at_text')
        expect(response.body).to include('receipt_attributes')
        expect(response.body).to include('purchased_at_fallback')
        expect(response.body).to include('ocr_time_candidate')
        expect(response.body).not_to include('_HORIZONTAL')
        expect(response.body).not_to include('sliders_horizontal')
        expect(response.body).not_to include('Analysis.retry_receipt_analysis')
        expect(response.body).not_to include('name="retry_kind"')
        expect(response.body).not_to include('確認文字列 RETRY ANALYSIS')
      end
    end

    it '画像付きreceiptならオリジナル画像カードと安全なmetadataを表示する' do
      admin = create(:user, :admin)
      receipt = create(:receipt, :completed, :with_image)
      receipt.image.blob.update!(metadata: receipt.image.blob.metadata.merge('width' => 640, 'height' => 480))
      run = create(:receipt_analysis_run, :succeeded, receipt:)
      sign_in admin

      get admin_receipt_analysis_run_path(run.run_key)

      document = Nokogiri::HTML(response.body)
      byte_size_label = ActiveSupport::NumberHelper.number_to_human_size(receipt.image.blob.byte_size)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('オリジナル画像')
        expect(response.body).to include('画像メタ情報')
        expect(response.body).to include('class="h-full" data-controller="receipt-image-card"')
        expect(document.css('section.surface-card-blur.h-full.flex.flex-col').size).to be >= 2
        expect(response.body).to include('receipt_sample.jpg')
        expect(response.body).to include('image/jpeg')
        expect(response.body).to include(byte_size_label)
        expect(response.body).to include('640 x 480')
        expect(response.body).to include('OCR input image')
        expect(response.body).to include('未実装。現在はオリジナル画像をOCRへ送信します。')
        expect(document.at_css('img[data-receipt-image-card-target="previewImage"]')).to be_present
        expect(document.css('a[download]')).to be_empty
        expect(response.body).not_to include(receipt.image.blob.key)
        expect(response.body).not_to include('signed_id')
        expect(response.body).not_to include('blob_key')
      end
    end

    it '画像なしreceiptでもオリジナル画像カードを安全に表示する' do
      admin = create(:user, :admin)
      receipt = create(:receipt, :completed)
      run = create(:receipt_analysis_run, :succeeded, receipt:)
      sign_in admin

      get admin_receipt_analysis_run_path(run.run_key)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('オリジナル画像')
        expect(response.body).to include('画像はありません')
        expect(response.body).to include('画像メタ情報')
        expect(response.body).to include('OCR result snapshot')
        expect(response.body).to include('AI normalized result snapshot')
        expect(response.body).to include('BuildParams snapshot')
        expect(response.body).to include('{}')
      end
    end

    it '画像purge済みreceiptではpurgeメタ情報を表示する' do
      admin = create(:user, :admin)
      purged_at = Time.zone.parse('2026-06-03 02:30:00')
      receipt = create(
        :receipt,
        :completed,
        keep_image: false,
        image_purged_at: purged_at,
        image_purged_reason: Receipt::IMAGE_PURGED_REASON_SYSTEM_PURGE
      )
      run = create(:receipt_analysis_run, :succeeded, receipt:)
      sign_in admin

      get admin_receipt_analysis_run_path(run.run_key)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('shared.receipt_image_card.unsaved_empty'))
        expect(response.body).to include(I18n.t('shared.receipt_image_card.system_purged_hint'))
        expect(response.body).to include('keep image')
        expect(response.body).to include('purged at')
        expect(response.body).to include('system_purge')
        expect(response.body).to include(I18n.l(purged_at, format: :short))
      end
    end

    it '非adminはshowを閲覧できない' do
      user = create(:user)
      run = create(:receipt_analysis_run, :succeeded, receipt: create(:receipt, :completed, :with_image))
      sign_in user

      get admin_receipt_analysis_run_path(run.run_key)

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.body).to include(I18n.t('errors.not_found.title'))
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
        },
        ocr_result_snapshot: {
          lines: [ 'safe OCR line' ],
          blob_key: 'BLOB KEY',
          api_key: 'API KEY',
          nested: {
            token: 'TOKEN',
            signed_id: 'SIGNED SNAPSHOT'
          }
        },
        ai_normalized_result_snapshot: {
          receipt_attributes: {
            purchased_at_text: '2026-04-19'
          },
          prompt_text: 'FULL SNAPSHOT PROMPT',
          full_prompt: 'FULL PROMPT SNAPSHOT BODY',
          system_prompt: 'SYSTEM PROMPT SNAPSHOT BODY',
          user_prompt: 'USER PROMPT SNAPSHOT BODY',
          openai_raw_response: 'RAW SNAPSHOT AI RESPONSE',
          raw_ai_response: 'RAW AI SNAPSHOT RESPONSE',
          image_payload: 'IMAGE PAYLOAD',
          nested: {
            secret: 'SNAPSHOT SECRET'
          }
        },
        metadata: {
          build_params_snapshot: {
            receipt_attributes: {
              purchased_at: '2026-04-19T16:41:00+09:00'
            },
            full_prompt: 'BUILD FULL PROMPT',
            blob_key: 'BUILD BLOB KEY',
            signed_id: 'BUILD SIGNED ID',
            api_key: 'BUILD API KEY',
            token: 'BUILD TOKEN',
            secret: 'BUILD SECRET'
          }
        }
      )
      sign_in admin

      get admin_receipt_analysis_run_path(run.run_key)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('safe content')
        expect(response.body).to include('safe OCR line')
        expect(response.body).to include('purchased_at_text')
        expect(response.body).to include('line_count')
        expect(response.body).not_to include('RAW OCR RESPONSE')
        expect(response.body).not_to include('FULL PROMPT')
        expect(response.body).not_to include('RAW AI RESPONSE')
        expect(response.body).not_to include('SECRET')
        expect(response.body).not_to include('SIGNED')
        expect(response.body).not_to include('BLOB KEY')
        expect(response.body).not_to include('API KEY')
        expect(response.body).not_to include('TOKEN')
        expect(response.body).not_to include('SIGNED SNAPSHOT')
        expect(response.body).not_to include('FULL SNAPSHOT PROMPT')
        expect(response.body).not_to include('FULL PROMPT SNAPSHOT BODY')
        expect(response.body).not_to include('SYSTEM PROMPT SNAPSHOT BODY')
        expect(response.body).not_to include('USER PROMPT SNAPSHOT BODY')
        expect(response.body).not_to include('RAW SNAPSHOT AI RESPONSE')
        expect(response.body).not_to include('RAW AI SNAPSHOT RESPONSE')
        expect(response.body).not_to include('IMAGE PAYLOAD')
        expect(response.body).not_to include('SNAPSHOT SECRET')
        expect(response.body).not_to include('BUILD FULL PROMPT')
        expect(response.body).not_to include('BUILD BLOB KEY')
        expect(response.body).not_to include('BUILD SIGNED ID')
        expect(response.body).not_to include('BUILD API KEY')
        expect(response.body).not_to include('BUILD TOKEN')
        expect(response.body).not_to include('BUILD SECRET')
      end
    end

    it 'fresh reauthなしではretry form/buttonを表示しない' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded)
      sign_in admin

      get admin_receipt_analysis_run_path(run.run_key)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('再解析にはパスキー再認証が必要です')
        expect(response.body).to include(new_admin_passkey_reauthentication_path)
        expect(response.body).not_to include('name="retry_kind"')
        expect(response.body).not_to include('再解析理由')
        expect(response.body).not_to include('value="再解析を実行"')
      end
    end

    it 'fresh reauth済みならretry form/buttonを表示する' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded, receipt: create(:receipt, :completed, :with_image))
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      get admin_receipt_analysis_run_path(run.run_key)

      document = Nokogiri::HTML(response.body)
      reason_textarea = document.at_css('textarea[name="reason"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('パスキー再認証済みです')
        expect(response.body).to include('name="retry_kind"')
        expect(response.body).to include('再解析理由')
        expect(response.body).to include('確認文字列 RETRY ANALYSIS')
        expect(response.body).to include('name="confirmation"')
        expect(response.body).to include('再解析を実行')
        expect(reason_textarea).to be_present
        expect(reason_textarea['class']).to include('py-2')
        expect(reason_textarea['class']).to include('leading-6')
      end
    end

    it 'AI停止中はai_retryをdisabled表示し実行フォームを出さない' do
      admin = create(:user, :admin)
      run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: create(:receipt, :completed, :with_image),
        ocr_result_snapshot: {
          'success' => true,
          'lines' => [ 'テストストア', '合計 1000' ],
          'candidates' => { 'store_name' => 'テストストア', 'total_amount' => 1000 },
          'meta' => {}
        }
      )
      create(:system_setting, key: 'operations.ai_enabled', value: SystemSettings.stored_value(false))
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)

      get admin_receipt_analysis_run_path(run.run_key)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('ai_retry')
        expect(response.body).to include('ai_unavailable')
        expect(response.body).not_to include('value="ai_retry"')
        expect(response.body).to include('value="full_reanalyze"')
      end
    end
  end

  describe 'POST /admin/receipt_analysis_runs/:run_key/retry' do
    it 'development/testでもfresh reauthなしではRetryServiceを呼ばずreauthへredirectする' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded)
      sign_in admin
      allow(Analysis).to receive(:retry_receipt_analysis)

      post retry_admin_receipt_analysis_run_path(run.run_key),
           params: {
             retry_type: 'full_reanalyze',
             reason: '問い合わせ対応',
             confirmation: 'RETRY ANALYSIS'
           }

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_receipt_analysis_run_path(run.run_key)))
        expect(flash[:alert]).to include('パスキーによる再認証')
        expect(Analysis).not_to have_received(:retry_receipt_analysis)
        expect(session.to_hash.to_json).not_to include('問い合わせ対応', 'full_reanalyze', 'RETRY ANALYSIS')
        expect_no_analysis_jobs_enqueued
      end
    end

    it 'RetryServiceが失敗した場合は元runへredirectしてalertを出す' do
      admin = create(:user, :admin)
      parent_run = create(:receipt_analysis_run, :succeeded)
      result = instance_double(
        'Analysis retry result',
        run: nil,
        success?: false,
        error_code: 'ocr_snapshot_missing',
        error_message: 'parent_run.ocr_result_snapshot is required'
      )
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)
      allow(Analysis).to receive(:retry_receipt_analysis).and_return(result)

      post retry_admin_receipt_analysis_run_path(parent_run.run_key),
           params: {
             retry_type: 'ai_retry',
             reason: 'AIだけ再実行',
             confirmation: 'RETRY ANALYSIS'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_run_path(parent_run.run_key))
        expect(flash[:alert]).to include('ocr_snapshot_missing')
        expect(Analysis).to have_received(:retry_receipt_analysis)
        expect_no_analysis_jobs_enqueued
      end
    end

    it 'reason blank はRetryServiceを呼ばずに拒否する' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)
      allow(Analysis).to receive(:retry_receipt_analysis)

      post retry_admin_receipt_analysis_run_path(run.run_key),
           params: {
             retry_type: 'full_reanalyze',
             reason: '',
             confirmation: 'RETRY ANALYSIS'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_run_path(run.run_key))
        expect(flash[:alert]).to include('再解析理由を入力してください')
        expect(Analysis).not_to have_received(:retry_receipt_analysis)
        expect_no_analysis_jobs_enqueued
      end
    end

    it 'invalid retry_type はRetryServiceを呼ばずに拒否する' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)
      allow(Analysis).to receive(:retry_receipt_analysis)

      post retry_admin_receipt_analysis_run_path(run.run_key),
           params: {
             retry_type: 'destroy_everything',
             reason: 'invalid',
             confirmation: 'RETRY ANALYSIS'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_run_path(run.run_key))
        expect(flash[:alert]).to include('再解析の種類を選択してください')
        expect(Analysis).not_to have_received(:retry_receipt_analysis)
        expect_no_analysis_jobs_enqueued
      end
    end

    it 'confirmation不一致はRetryServiceを呼ばずに拒否する' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)
      allow(Analysis).to receive(:retry_receipt_analysis)

      post retry_admin_receipt_analysis_run_path(run.run_key),
           params: {
             retry_type: 'full_reanalyze',
             reason: 'confirmation mismatch',
             confirmation: 'WRONG'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_run_path(run.run_key))
        expect(flash[:alert]).to include('確認文字列')
        expect(Analysis).not_to have_received(:retry_receipt_analysis)
        expect_no_analysis_jobs_enqueued
      end
    end

    it 'confirmationなしはRetryServiceを呼ばずに拒否する' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded)
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)
      allow(Analysis).to receive(:retry_receipt_analysis)

      post retry_admin_receipt_analysis_run_path(run.run_key),
           params: {
             retry_type: 'full_reanalyze',
             reason: 'missing confirmation'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_run_path(run.run_key))
        expect(flash[:alert]).to include('確認文字列')
        expect(Analysis).not_to have_received(:retry_receipt_analysis)
        expect_no_analysis_jobs_enqueued
      end
    end

    it 'fresh reauthなしならRetryServiceを呼ばずreauthへredirectする' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded)
      sign_in admin
      allow(Analysis).to receive(:retry_receipt_analysis)

      post retry_admin_receipt_analysis_run_path(run.run_key),
           params: {
             retry_type: 'full_reanalyze',
             reason: 'fresh reauth missing',
             confirmation: 'RETRY ANALYSIS'
           }

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_receipt_analysis_run_path(run.run_key)))
        expect(flash[:alert]).to include('パスキーによる再認証')
        expect(Analysis).not_to have_received(:retry_receipt_analysis)
        expect(session.to_hash.to_json).not_to include('fresh reauth missing', 'full_reanalyze', 'RETRY ANALYSIS')
        expect_no_analysis_jobs_enqueued
      end
    end

    it 'passkey未登録adminもRetryServiceを呼ばずreauthへredirectする' do
      admin = create(:user, :admin)
      run = create(:receipt_analysis_run, :succeeded)
      sign_in admin
      allow(Analysis).to receive(:retry_receipt_analysis)

      post retry_admin_receipt_analysis_run_path(run.run_key),
           params: {
             retry_type: 'full_reanalyze',
             reason: 'passkey missing',
             confirmation: 'RETRY ANALYSIS'
           }

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_receipt_analysis_run_path(run.run_key)))
        expect(Analysis).not_to have_received(:retry_receipt_analysis)
        expect_no_analysis_jobs_enqueued
      end
    end

    it 'fresh reauth + reason + confirmationでRetryServiceへreauthentication metadataを渡す' do
      admin = create(:user, :admin)
      parent_run = create(:receipt_analysis_run, :succeeded, receipt: create(:receipt, :completed, :with_image))
      new_run = create(:receipt_analysis_run, receipt: parent_run.receipt, parent_run: parent_run)
      result = instance_double(
        'Analysis retry result',
        run: new_run,
        success?: true
      )
      sign_in admin
      reauthenticate_admin_with_passkey!(admin)
      allow(Analysis).to receive(:retry_receipt_analysis).and_return(result)

      post retry_admin_receipt_analysis_run_path(parent_run.run_key),
           params: {
             retry_type: 'full_reanalyze',
             reason: 'fresh retry',
             confirmation: 'RETRY ANALYSIS'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_receipt_analysis_run_path(new_run.run_key))
        expect(Analysis).to have_received(:retry_receipt_analysis).with(
          receipt: parent_run.receipt,
          parent_run: parent_run,
          actor: admin,
          retry_type: 'full_reanalyze',
          reason: 'fresh retry',
          request: kind_of(ActionDispatch::Request),
          confirmation: 'RETRY ANALYSIS',
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
             reason: 'not admin',
             confirmation: 'RETRY ANALYSIS'
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
      reauthenticate_admin_with_passkey!(admin)

      expect do
        post retry_admin_receipt_analysis_run_path(parent_run.run_key),
             params: {
               retry_type: 'full_reanalyze',
               reason: '監査ログ確認',
               confirmation: 'RETRY ANALYSIS'
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
        expect(audit_log.metadata).to include(
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey'
        )
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
