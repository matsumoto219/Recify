require 'rails_helper'

RSpec.describe Admin::ReceiptAnalysisRunsQuery do
  include ActiveSupport::Testing::TimeHelpers

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

      expect(ReceiptAnalysisRun).to have_received(:includes).with(:requested_by_user, receipt: :user)
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

    it 'RetryServiceのread-only eligibilityをrecordに含め、enqueueしない' do
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
      allow(Analysis::RetryService).to receive(:eligibility).and_call_original
      allow(ReceiptOcrJob).to receive(:perform_later)
      allow(ReceiptAiEnrichmentJob).to receive(:perform_later)
      allow(ReceiptFinalizeJob).to receive(:perform_later)

      record = described_class.call(receipt: receipt).records.first

      aggregate_failures do
        expect(Analysis::RetryService).to have_received(:eligibility).with(receipt: receipt, parent_run: run)
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
