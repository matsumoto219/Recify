require 'rails_helper'

RSpec.describe Admin::ReceiptAnalysisRunsQuery do
  include ActiveSupport::Testing::TimeHelpers

  def count_application_queries
    queries = []
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      next if %w[SCHEMA TRANSACTION CACHE].include?(payload[:name].to_s)

      queries << payload[:sql]
    end

    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { yield }
    queries.size
  end

  around do |example|
    travel_to(Time.zone.parse('2026-05-23 10:00:00')) { example.run }
  end

  describe '.call' do
    it 'latest順で管理画面用recordを返す' do
      older = create(:receipt_analysis_run, :succeeded, created_at: 2.hours.ago)
      newer = create(:receipt_analysis_run, :failed, created_at: 1.hour.ago)

      result = Admin.receipt_analysis_runs

      aggregate_failures do
        expect(result.records.map { |record| record[:run] }).to start_with(newer, older)
        expect(result.records.first).to include(
          run: newer,
          run_key: newer.run_key,
          receipt: newer.receipt,
          user: newer.receipt.user,
          public_id: newer.receipt.public_id,
          display_id: newer.receipt.display_id,
          stage: newer.stage,
          status: newer.status,
          source: newer.source
        )
        expect(result.limit).to eq(50)
        expect(result.offset).to eq(0)
        expect(result.total_count).to eq(2)
      end
    end

    it 'run_keyで絞り込める' do
      target_run = create(:receipt_analysis_run, :succeeded)
      create(:receipt_analysis_run, :succeeded)

      result = described_class.call(run_key: target_run.run_key)

      aggregate_failures do
        expect(result.records.map { |record| record[:run] }).to eq([ target_run ])
        expect(result.records.first[:run_key]).to eq(target_run.run_key)
      end
    end

    it 'receipt / userで絞り込める' do
      target_user = create(:user)
      target_receipt = create(:receipt, user: target_user)
      target_run = create(:receipt_analysis_run, :succeeded, receipt: target_receipt)
      other_user_run = create(:receipt_analysis_run, :succeeded)
      other_receipt_run = create(:receipt_analysis_run, :succeeded, receipt: create(:receipt, user: target_user))

      aggregate_failures do
        expect(described_class.call(receipt: target_receipt).records.map { |record| record[:run] }).to eq([ target_run ])
        expect(described_class.call(receipt_public_id: target_receipt.public_id).records.map { |record| record[:run] }).to eq([ target_run ])
        expect(described_class.call(user: target_user).records.map { |record| record[:run] }).to contain_exactly(target_run, other_receipt_run)
        expect(described_class.call(user: other_user_run.receipt.user).records.map { |record| record[:run] }).to eq([ other_user_run ])
      end
    end

    describe 'Receipt ID filter contract' do
      it 'public IDをtrim後もcase-sensitiveな完全一致で検索する' do
        receipt = create(:receipt, public_id: 'rcpt_Ab12Cd34Ef56Gh78')
        runs = [
          create(:receipt_analysis_run, :succeeded, receipt:, created_at: 2.minutes.ago),
          create(:receipt_analysis_run, :failed, receipt:, created_at: 1.minute.ago)
        ]
        create(:receipt_analysis_run, :succeeded)

        aggregate_failures do
          expect(described_class.call(receipt_public_id: " \trcpt_Ab12Cd34Ef56Gh78\n").records.map { |record| record[:run] })
            .to eq(runs.reverse)
          expect(described_class.call(receipt_public_id: 'rcpt_ab12cd34ef56gh78').records).to be_empty
          expect(described_class.call(receipt_public_id: 'rcpt_Ab12Cd34').records).to be_empty
          expect(described_class.call(receipt_public_id: 'rcpt_%').records).to be_empty
        end
      end

      it 'display IDをtrimしlowercaseだけを正規化して完全一致検索する' do
        receipt = create(:receipt, display_id: 'R-ABC123')
        run = create(:receipt_analysis_run, :succeeded, receipt:)
        create(:receipt_analysis_run, :succeeded)

        aggregate_failures do
          expect(described_class.call(receipt_public_id: 'R-ABC123').records.map { |record| record[:run] }).to eq([ run ])
          expect(described_class.call(receipt_public_id: " \tr-abc123\n").records.map { |record| record[:run] }).to eq([ run ])
          expect(described_class.call(receipt_public_id: 'R-ABC12').records).to be_empty
          expect(described_class.call(receipt_public_id: 'R-ABC123%').records).to be_empty
          expect(described_class.call(receipt_public_id: receipt.id.to_s).records).to be_empty
        end
      end

      it '衝突するdisplay IDを持つ全Receiptの全runを重複なく安定順で返す' do
        first_receipt = create(:receipt, display_id: 'R-ABC123')
        second_receipt = create(:receipt, display_id: 'R-ABC123')
        unrelated_receipt = create(:receipt, display_id: 'R-OTHER1')
        shared_time = 30.minutes.ago
        matching_runs = [
          create(:receipt_analysis_run, :succeeded, receipt: first_receipt, created_at: 2.hours.ago),
          create(:receipt_analysis_run, :failed, receipt: first_receipt, created_at: shared_time),
          create(:receipt_analysis_run, :succeeded, receipt: second_receipt, created_at: 1.hour.ago),
          create(:receipt_analysis_run, :failed, receipt: second_receipt, created_at: shared_time)
        ]
        create(:receipt_analysis_run, :succeeded, receipt: unrelated_receipt, created_at: 1.minute.ago)

        result = described_class.call(receipt_public_id: 'R-ABC123', limit: 2, offset: 0)
        next_page = described_class.call(receipt_public_id: 'R-ABC123', limit: 2, offset: 2)
        expected = matching_runs.sort_by { |run| [ run.created_at, run.id ] }.reverse
        records = result.records + next_page.records

        aggregate_failures do
          expect(result.total_count).to eq(4)
          expect(next_page.total_count).to eq(4)
          expect(records.map { |record| record[:run] }).to eq(expected)
          expect(records.map { |record| record[:run].id }.uniq.size).to eq(4)
          expect(records.map { |record| record[:receipt] }).to include(first_receipt, second_receipt)
          expect(records).to all(include(:run_key, :display_id, :public_id, :user_info))
        end
      end

      it 'display/public IDと既存user_id filterをANDで結合する' do
        first_user = create(:user)
        second_user = create(:user)
        unrelated_user = create(:user)
        first_receipt = create(:receipt, user: first_user, display_id: 'R-ABC123', public_id: 'rcpt_Aa11Bb22Cc33Dd44')
        second_receipt = create(:receipt, user: second_user, display_id: 'R-ABC123', public_id: 'rcpt_Ee55Ff66Gg77Hh88')
        first_run = create(:receipt_analysis_run, :succeeded, receipt: first_receipt)
        second_run = create(:receipt_analysis_run, :succeeded, receipt: second_receipt)

        aggregate_failures do
          expect(described_class.call(receipt_public_id: 'R-ABC123', user_id: first_user.id).records.map { |record| record[:run] }).to eq([ first_run ])
          expect(described_class.call(receipt_public_id: 'R-ABC123', user_id: second_user.id).records.map { |record| record[:run] }).to eq([ second_run ])
          expect(described_class.call(receipt_public_id: 'R-ABC123', user_id: unrelated_user.id).records).to be_empty
          expect(described_class.call(receipt_public_id: first_receipt.public_id, user_id: first_user.id).records.map { |record| record[:run] }).to eq([ first_run ])
          expect(described_class.call(receipt_public_id: first_receipt.public_id, user_id: second_user.id).records).to be_empty
        end
      end

      it 'Receipt IDと既存run filterをANDで結合する' do
        receipt = create(:receipt, display_id: 'R-ABC123')
        matching_run = create(:receipt_analysis_run, :failed, receipt:, source: 'admin_retry')
        create(:receipt_analysis_run, :succeeded, receipt:, source: 'upload')
        create(:receipt_analysis_run, :failed, source: 'admin_retry')

        result = described_class.call(
          receipt_public_id: 'R-ABC123',
          status: 'failed',
          source: 'admin_retry'
        )

        expect(result.records.map { |record| record[:run] }).to eq([ matching_run ])
      end

      it 'malformedまたは非IDのnonblank入力を例外なく0件にし全件表示へ戻さない' do
        create(:receipt_analysis_run, :succeeded)
        abnormal_object = Object.new
        abnormal_object.define_singleton_method(:to_s) { raise 'must not coerce' }
        malformed_values = [
          'ordinary text',
          'R-ABC',
          'R-ABCDEFG',
          'R-AB!123',
          'rcpt_Ab12',
          'rcpt_Ab12Cd34Ef56Gh789',
          'RCPT_Ab12Cd34Ef56Gh78',
          '%',
          '_',
          '*',
          '123',
          "R-AB\0C12",
          'Ｒ－ＡＢＣ１２３',
          'R-' + ('A' * 10_000),
          [],
          {},
          abnormal_object
        ]

        aggregate_failures do
          malformed_values.each do |value|
            result = nil
            expect { result = described_class.call(receipt_public_id: value) }.not_to raise_error
            next unless result

            expect(result.records).to be_empty, "expected #{value.inspect} to return no records"
            expect(result.total_count).to eq(0)
          end
        end
      end

      it 'nil、blank、whitespaceだけはReceipt ID filterなしとして扱う' do
        runs = [
          create(:receipt_analysis_run, :succeeded, created_at: 2.minutes.ago),
          create(:receipt_analysis_run, :failed, created_at: 1.minute.ago)
        ]

        aggregate_failures do
          [ nil, '', " \t\n" ].each do |value|
            expect(described_class.call(receipt_public_id: value).records.map { |record| record[:run] })
              .to eq(runs.reverse)
          end
        end
      end
    end

    it 'status / stage / source / error_codeで絞り込める' do
      failed_run = create(
        :receipt_analysis_run,
        :failed,
        stage: 'completed',
        source: 'upload',
        error_code: 'ai_api_error'
      )
      processing_error_run = create(
        :receipt_analysis_run,
        :succeeded,
        source: 'batch_upload',
        final_result_summary: { processing_error_code: 'ocr_unreadable', receipt_status: 'failed' }
      )
      create(:receipt_analysis_run, :succeeded, source: 'admin_retry')

      aggregate_failures do
        expect(described_class.call(status: 'failed').records.map { |record| record[:run] }).to eq([ failed_run ])
        expect(described_class.call(stage: 'completed').records.map { |record| record[:run] }).to include(failed_run)
        expect(described_class.call(source: 'batch_upload').records.map { |record| record[:run] }).to eq([ processing_error_run ])
        expect(described_class.call(error_code: 'ai_api_error').records.map { |record| record[:run] }).to eq([ failed_run ])
        expect(described_class.call(error_code: 'ocr_unreadable').records.map { |record| record[:run] }).to eq([ processing_error_run ])
      end
    end

    it 'fallback保存されたprocessing_error_codeで絞り込み、admin表示用error_codeへ反映する' do
      fallback_run = create(
        :receipt_analysis_run,
        :succeeded,
        final_result_summary: { processing_error_code: 'ai_primary_failed', receipt_status: 'review_needed' }
      )

      result = described_class.call(error_code: 'ai_primary_failed')

      aggregate_failures do
        expect(result.records.map { |record| record[:run] }).to eq([ fallback_run ])
        expect(result.records.first[:error_code]).to eq('ai_primary_failed')
        expect(result.records.first[:processing_error_code]).to eq('ai_primary_failed')
      end
    end

    it 'receipt_status / needs_attention / expires_beforeで絞り込める' do
      completed_run = create(
        :receipt_analysis_run,
        :succeeded,
        final_result_summary: { receipt_status: 'completed' },
        expires_at: 20.days.from_now
      )
      review_needed_run = create(
        :receipt_analysis_run,
        :succeeded,
        final_result_summary: { receipt_status: 'review_needed' },
        expires_at: 80.days.from_now
      )
      failed_receipt_run = create(
        :receipt_analysis_run,
        :succeeded,
        final_result_summary: { receipt_status: 'failed' },
        expires_at: 80.days.from_now
      )
      pipeline_failed_run = create(:receipt_analysis_run, :failed, expires_at: 80.days.from_now)

      aggregate_failures do
        expect(described_class.call(receipt_status: 'review_needed').records.map { |record| record[:run] }).to eq([ review_needed_run ])
        expect(described_class.call(needs_attention: true).records.map { |record| record[:run] }).to contain_exactly(
          review_needed_run,
          failed_receipt_run,
          pipeline_failed_run
        )
        expect(described_class.call(expires_before: 30.days.from_now).records.map { |record| record[:run] }).to eq([ completed_run ])
      end
    end

    it 'limit上限とoffsetを適用する' do
      runs = Array.new(3) { |index| create(:receipt_analysis_run, :succeeded, created_at: index.minutes.ago) }

      result = described_class.call(limit: 500, offset: 1)

      aggregate_failures do
        expect(result.limit).to eq(100)
        expect(result.offset).to eq(1)
        expect(result.total_count).to eq(3)
        expect(result.records.map { |record| record[:run] }).to eq(runs.sort_by(&:created_at).reverse.drop(1))
      end
    end

    it 'receipt / user をeager loadする' do
      allow(ReceiptAnalysisRun).to receive(:includes).and_call_original

      described_class.call

      expect(ReceiptAnalysisRun).to have_received(:includes).with(
        :requested_by_user,
        { ocr_response_artifact_attachment: :blob },
        receipt: :user
      )
    end

    it 'display ID衝突でrun数が増えてもartifact参照をN+1にしない' do
      single_receipt = create(:receipt, display_id: 'R-SINGL1')
      create(:receipt_analysis_run, :succeeded, receipt: single_receipt)
      collision_receipts = Array.new(4) { create(:receipt, display_id: 'R-COLLID') }
      collision_receipts.each do |receipt|
        create_list(:receipt_analysis_run, 2, :succeeded, receipt:)
      end

      single_query_count = count_application_queries do
        described_class.call(receipt_public_id: 'R-SINGL1')
      end
      collision_query_count = count_application_queries do
        described_class.call(receipt_public_id: 'R-COLLID')
      end

      expect(collision_query_count).to eq(single_query_count)
    end

    it '一覧向けrecordではretry_optionsを作らない' do
      create(:receipt_analysis_run, :succeeded)
      allow(Receipts::Processing).to receive(:admin_retry_eligibility).and_call_original

      record = described_class.call.records.first

      aggregate_failures do
        expect(record).not_to have_key(:retry_options)
        expect(Receipts::Processing).not_to have_received(:admin_retry_eligibility)
      end
    end

    it 'summaryからrawやsecret系のキーを除外する' do
      run = create(
        :receipt_analysis_run,
        :succeeded,
        ocr_summary: {
          schema_version: 'test',
          raw_response: 'RAW OCR RESPONSE',
          nested: {
            secret_token: 'SECRET',
            line_count: 3
          }
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

      record = described_class.call(receipt: run.receipt).records.first
      summary_json = JSON.generate(record[:summaries])

      aggregate_failures do
        expect(summary_json).to include('safe content')
        expect(summary_json).to include('line_count')
        expect(summary_json).not_to include('RAW OCR RESPONSE')
        expect(summary_json).not_to include('FULL PROMPT')
        expect(summary_json).not_to include('RAW AI RESPONSE')
        expect(summary_json).not_to include('SECRET')
        expect(summary_json).not_to include('SIGNED')
      end
    end

    it 'OCR polling metricsをrecordに含める' do
      run = create(
        :receipt_analysis_run,
        :succeeded,
        ocr_summary: {
          polling_metrics: {
            poll_count: 3,
            max_poll_count: 20,
            final_status: 'succeeded',
            total_poll_sleep_ms: 5500,
            max_poll_interval: 3.0,
            poll_backoff_factor: 1.5,
            retry_after_used: true
          }
        },
        ocr_result_snapshot: {
          meta: {
            polling_metrics: {
              poll_count: 2,
              final_status: 'fallback'
            }
          }
        }
      )

      record = described_class.call(receipt: run.receipt).records.first

      expect(record[:polling_metrics]).to include(
        'poll_count' => 3,
        'max_poll_count' => 20,
        'final_status' => 'succeeded',
        'total_poll_sleep_ms' => 5500,
        'max_poll_interval' => 3.0,
        'poll_backoff_factor' => 1.5,
        'retry_after_used' => true
      )
    end

    it 'AI metricsをrecordに含める' do
      run = create(
        :receipt_analysis_run,
        :succeeded,
        ai_result_summary: {
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
            response_id: 'resp_123',
            fallback_used: true,
            fallback_provider: 'backup-provider',
            fallback_reason: 'ai_api_error',
            final_provider: 'backup-provider'
          }
        },
        ai_normalized_result_snapshot: {
          meta: {
            metrics: {
              provider: 'openai',
              retry_count: 1
            }
          }
        }
      )

      record = described_class.call(receipt: run.receipt).records.first

      expect(record[:ai_metrics]).to include(
        'provider' => 'openai',
        'model' => 'gpt-test',
        'elapsed_ms' => 1200,
        'retry_count' => 2,
        'retry_after_used' => true,
        'total_retry_sleep_ms' => 4000,
        'rate_limited' => true,
        'provider_status' => '429',
        'response_id' => 'resp_123',
        'fallback_used' => true,
        'fallback_provider' => 'backup-provider',
        'fallback_reason' => 'ai_api_error',
        'final_provider' => 'backup-provider'
      )
      expect(record.dig(:ai_metrics, 'token_usage')).to eq(
        'input_tokens' => 100,
        'output_tokens' => 20,
        'total_tokens' => 120
      )
    end

    it 'include_retry_optionsが有効な場合だけRetryServiceのread-only eligibilityをrecordに含め、enqueueしない' do
      receipt = create(:receipt, :completed, :with_image)
      run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: {
          schema_version: 'receipt_analysis_run_ocr_result_v1',
          success: true,
          lines: [ '合計 1000' ],
          candidates: { total_amount: 1000 }
        },
        ai_normalized_result_snapshot: {
          schema_version: 'receipt_analysis_run_ai_normalized_result_v1',
          success: true,
          receipt_attributes: { total_amount: 1000 },
          receipt_items_attributes: []
        },
        metadata: {
          'finalize_decision' => {
            schema_version: 'receipt_analysis_run_finalize_decision_v1',
            strategy: 'ai_success',
            recorded_at: Time.current.iso8601
          }
        }
      )
      allow(Receipts::Processing).to receive(:admin_retry_eligibility).and_call_original
      allow(ReceiptOcrJob).to receive(:perform_later)
      allow(ReceiptAiEnrichmentJob).to receive(:perform_later)
      allow(ReceiptFinalizeJob).to receive(:perform_later)

      record = described_class.call(receipt: receipt, include_retry_options: true).records.first

      aggregate_failures do
        expect(Receipts::Processing).to have_received(:admin_retry_eligibility).with(receipt: receipt, parent_run: run)
        expect(record[:retry_options]).to eq(
          [
            { type: 'full_reanalyze', possible: true, disabled_reason: nil },
            { type: 'ocr_retry', possible: true, disabled_reason: nil },
            { type: 'ai_retry', possible: true, disabled_reason: nil },
            { type: 'finalize_retry', possible: true, disabled_reason: nil }
          ]
        )
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
        expect(ReceiptAiEnrichmentJob).not_to have_received(:perform_later)
        expect(ReceiptFinalizeJob).not_to have_received(:perform_later)
      end
    end
  end
end
