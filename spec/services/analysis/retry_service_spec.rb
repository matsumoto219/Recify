require 'rails_helper'

RSpec.describe Analysis::RetryService do
  include ActiveJob::TestHelper

  let(:actor) { create(:user) }
  let(:receipt) do
    create(
      :receipt,
      :completed,
      :with_image,
      processing_error_code: 'ai_api_error',
      processing_error_message: 'AI failed',
      review_reasons: [ 'ai_fallback' ]
    )
  end

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs

    example.run
  ensure
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = original_adapter
  end

  describe '.call' do
    it 'full_reanalyzeでnew runを作り、ReceiptOcrJobをrun_idだけでenqueueする' do
      result = described_class.call(
        receipt: receipt,
        actor: actor,
        retry_type: :full_reanalyze,
        reason: '問い合わせ対応'
      )

      aggregate_failures do
        expect(result).to be_success
        expect(result.retry_type).to eq('full_reanalyze')
        expect(result.enqueued_job).to eq(ReceiptOcrJob)
        expect(result.run).to be_persisted
        expect(result.run.source).to eq('admin_retry')
        expect(result.run.requested_by_user).to eq(actor)
        expect(result.run.request_reason).to eq('問い合わせ対応')
        expect(result.run.parent_run).to be_nil
        expect(result.run.stage).to eq('queued')
        expect(result.run.status).to eq('queued')
        expect(receipt.reload).to be_processing
        expect(receipt.processing_error_code).to be_nil
        expect(receipt.processing_error_message).to be_nil
        expect(receipt.review_reasons).to eq([])
        expect(ReceiptOcrJob).to have_been_enqueued.with(run_id: result.run.id)
        expect(enqueued_jobs.last[:args]).to eq([ { 'run_id' => result.run.id, '_aj_ruby2_keywords' => [ 'run_id' ] } ])
      end
    end

    it 'ocr_retryでparent_runを紐づけ、ReceiptOcrJobをenqueueする' do
      parent_run = create(:receipt_analysis_run, :succeeded, receipt: receipt)

      result = described_class.call(
        receipt: receipt,
        parent_run: parent_run,
        actor: actor,
        retry_type: :ocr_retry,
        reason: 'OCRだけ再実行'
      )

      aggregate_failures do
        expect(result).to be_success
        expect(result.run.parent_run).to eq(parent_run)
        expect(result.run.requested_by_user).to eq(actor)
        expect(result.run.request_reason).to eq('OCRだけ再実行')
        expect(ReceiptOcrJob).to have_been_enqueued.with(run_id: result.run.id)
        expect(ReceiptAiEnrichmentJob).not_to have_been_enqueued
        expect(ReceiptFinalizeJob).not_to have_been_enqueued
      end
    end

    it 'ai_retryでOCR snapshotをコピーし、ReceiptAiEnrichmentJobをenqueueする' do
      parent_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_summary: parent_ocr_summary,
        ocr_result_snapshot: parent_ocr_snapshot
      )
      original_parent_state = parent_state(parent_run)

      result = described_class.call(
        receipt: receipt,
        parent_run: parent_run,
        actor: actor,
        retry_type: :ai_retry,
        reason: 'AIだけ再実行'
      )

      run = result.run.reload

      aggregate_failures do
        expect(result).to be_success
        expect(run.parent_run).to eq(parent_run)
        expect(run.ocr_summary).to include(
          'schema_version' => 'receipt_analysis_run_ocr_summary_v1',
          'success' => true,
          'item_count' => 1
        )
        expect(run.ocr_summary).not_to have_key('raw_response')
        expect(run.ocr_result_snapshot).to include(
          'schema_version' => 'receipt_analysis_run_ocr_result_v1',
          'success' => true,
          'lines' => [ 'スマイル', '合計 2998' ]
        )
        expect(run.ocr_result_snapshot.dig('candidates', 'items').first).to include('raw_text' => 'アメリカ産米')
        expect(snapshot_json(run)).not_to include('full raw OCR text')
        expect(snapshot_json(run)).not_to include('provider raw')
        expect(snapshot_json(run)).not_to include('secret-token')
        expect(ReceiptAiEnrichmentJob).to have_been_enqueued.with(run_id: run.id)
        expect(ReceiptOcrJob).not_to have_been_enqueued
        expect(ReceiptFinalizeJob).not_to have_been_enqueued
        expect(parent_state(parent_run.reload)).to eq(original_parent_state)
      end
    end

    it 'finalize_retryでOCR/AI snapshotとfinalize_decisionをコピーし、ReceiptFinalizeJobをenqueueする' do
      parent_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_summary: parent_ocr_summary,
        ocr_result_snapshot: parent_ocr_snapshot,
        ai_result_summary: parent_ai_summary,
        ai_normalized_result_snapshot: parent_ai_snapshot,
        metadata: {
          'kept' => 'existing-parent-metadata',
          'finalize_decision' => parent_finalize_decision_snapshot.merge(
            'prompt' => 'do-not-copy',
            'messages' => [ 'do-not-copy' ],
            'secret' => 'do-not-copy'
          )
        }
      )
      original_parent_state = parent_state(parent_run)

      result = described_class.call(
        receipt: receipt,
        parent_run: parent_run,
        actor: actor,
        retry_type: :finalize_retry,
        reason: '保存だけ再実行'
      )

      run = result.run.reload

      aggregate_failures do
        expect(result).to be_success
        expect(run.ocr_result_snapshot).to include('schema_version' => 'receipt_analysis_run_ocr_result_v1')
        expect(run.ai_result_summary).to include('schema_version' => 'receipt_analysis_run_ai_result_v1')
        expect(run.ai_normalized_result_snapshot).to include(
          'schema_version' => 'receipt_analysis_run_ai_normalized_result_v1',
          'success' => true
        )
        expect(run.metadata.keys).to contain_exactly('finalize_decision')
        expect(run.metadata.dig('finalize_decision', 'strategy')).to eq('ai_success')
        expect(snapshot_json(run)).not_to include('full raw OCR text')
        expect(snapshot_json(run)).not_to include('do-not-copy')
        expect(snapshot_json(run)).not_to include('provider raw')
        expect(ReceiptFinalizeJob).to have_been_enqueued.with(run_id: run.id)
        expect(ReceiptOcrJob).not_to have_been_enqueued
        expect(ReceiptAiEnrichmentJob).not_to have_been_enqueued
        expect(parent_state(parent_run.reload)).to eq(original_parent_state)
      end
    end

    it 'active runがある場合は失敗し、enqueueしない' do
      active_run = create(:receipt_analysis_run, :running, receipt: receipt)

      result = described_class.call(
        receipt: receipt,
        parent_run: nil,
        actor: actor,
        retry_type: :full_reanalyze
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('active_run_exists')
        expect(result.run).to eq(active_run)
        expect(ReceiptAnalysisRun.where(receipt: receipt).count).to eq(1)
        expect_no_analysis_job_enqueued
      end
    end

    it 'ai_retryでOCR snapshotがない場合は失敗し、run作成もenqueueもしない' do
      parent_run = create(:receipt_analysis_run, :succeeded, receipt: receipt, ocr_result_snapshot: {})

      expect do
        result = described_class.call(
          receipt: receipt,
          parent_run: parent_run,
          actor: actor,
          retry_type: :ai_retry
        )

        expect(result).to be_failure
        expect(result.error_code).to eq('ocr_snapshot_missing')
      end.not_to change(ReceiptAnalysisRun, :count)

      expect_no_analysis_job_enqueued
    end

    it 'full_reanalyzeで画像がない場合は失敗し、run作成もenqueueもしない' do
      receipt_without_image = create(:receipt, :completed)

      expect do
        result = described_class.call(
          receipt: receipt_without_image,
          actor: actor,
          retry_type: :full_reanalyze
        )

        expect(result).to be_failure
        expect(result.error_code).to eq('image_missing')
      end.not_to change(ReceiptAnalysisRun, :count)

      expect_no_analysis_job_enqueued
    end

    it 'finalize_retryでfinalize_decisionがない場合は失敗し、run作成もenqueueもしない' do
      parent_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: parent_ocr_snapshot,
        ai_normalized_result_snapshot: parent_ai_snapshot,
        metadata: {}
      )

      expect do
        result = described_class.call(
          receipt: receipt,
          parent_run: parent_run,
          actor: actor,
          retry_type: :finalize_retry
        )

        expect(result).to be_failure
        expect(result.error_code).to eq('finalize_decision_missing')
      end.not_to change(ReceiptAnalysisRun, :count)

      expect_no_analysis_job_enqueued
    end

    it 'finalize_retryでAI snapshotがない場合は失敗し、enqueueしない' do
      parent_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: parent_ocr_snapshot,
        ai_normalized_result_snapshot: {},
        metadata: { 'finalize_decision' => parent_finalize_decision_snapshot }
      )

      result = described_class.call(
        receipt: receipt,
        parent_run: parent_run,
        actor: actor,
        retry_type: :finalize_retry
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('ai_snapshot_missing')
        expect_no_analysis_job_enqueued
      end
    end

    it '未知のretry_typeは失敗し、enqueueしない' do
      result = described_class.call(
        receipt: receipt,
        actor: actor,
        retry_type: :unknown_retry
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('invalid_retry_type')
        expect_no_analysis_job_enqueued
      end
    end
  end

  describe '.eligibility' do
    it 'enqueueもDB更新もせず、retry_optionsを返す' do
      parent_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: parent_ocr_snapshot,
        ai_normalized_result_snapshot: parent_ai_snapshot,
        metadata: { 'finalize_decision' => parent_finalize_decision_snapshot }
      )

      expect do
        result = described_class.eligibility(receipt: receipt, parent_run: parent_run)

        aggregate_failures do
          expect(result.retry_options).to eq(
            [
              { type: 'full_reanalyze', possible: true, disabled_reason: nil },
              { type: 'ocr_retry', possible: true, disabled_reason: nil },
              { type: 'ai_retry', possible: true, disabled_reason: nil },
              { type: 'finalize_retry', possible: true, disabled_reason: nil }
            ]
          )
          expect_no_analysis_job_enqueued
        end
      end.not_to change { parent_run.reload.attributes }
    end

    it 'active runがある場合は全retry不可にする' do
      create(:receipt_analysis_run, :running, receipt: receipt)

      options = described_class.eligibility(receipt: receipt, parent_run: nil).retry_options

      aggregate_failures do
        expect(options.map { |option| option[:possible] }).to all(be(false))
        expect(options.map { |option| option[:disabled_reason] }).to all(eq('active_run_exists'))
      end
    end

    it '画像がない場合はfull_reanalyze / ocr_retryを不可にする' do
      receipt_without_image = create(:receipt, :completed)

      options = options_by_type(described_class.eligibility(receipt: receipt_without_image, parent_run: nil))

      aggregate_failures do
        expect(options['full_reanalyze']).to include(possible: false, disabled_reason: 'image_missing')
        expect(options['ocr_retry']).to include(possible: false, disabled_reason: 'image_missing')
      end
    end

    it 'OCR snapshotがある場合だけai_retryを可能にする' do
      missing_snapshot_run = create(:receipt_analysis_run, :succeeded, receipt: receipt, ocr_result_snapshot: {})
      ready_run = create(:receipt_analysis_run, :succeeded, receipt: receipt, ocr_result_snapshot: parent_ocr_snapshot)

      missing_options = options_by_type(described_class.eligibility(receipt: receipt, parent_run: missing_snapshot_run))
      ready_options = options_by_type(described_class.eligibility(receipt: receipt, parent_run: ready_run))

      aggregate_failures do
        expect(missing_options['ai_retry']).to include(possible: false, disabled_reason: 'ocr_snapshot_missing')
        expect(ready_options['ai_retry']).to include(possible: true, disabled_reason: nil)
      end
    end

    it 'finalize_retryの不足snapshotごとにdisabled_reasonを返す' do
      no_ocr_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: {},
        ai_normalized_result_snapshot: parent_ai_snapshot,
        metadata: { 'finalize_decision' => parent_finalize_decision_snapshot }
      )
      no_ai_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: parent_ocr_snapshot,
        ai_normalized_result_snapshot: {},
        metadata: { 'finalize_decision' => parent_finalize_decision_snapshot }
      )
      no_decision_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: parent_ocr_snapshot,
        ai_normalized_result_snapshot: parent_ai_snapshot,
        metadata: {}
      )
      ready_run = create(
        :receipt_analysis_run,
        :succeeded,
        receipt: receipt,
        ocr_result_snapshot: parent_ocr_snapshot,
        ai_normalized_result_snapshot: parent_ai_snapshot,
        metadata: { 'finalize_decision' => parent_finalize_decision_snapshot }
      )

      aggregate_failures do
        expect(options_by_type(described_class.eligibility(receipt: receipt, parent_run: no_ocr_run))['finalize_retry']).to include(possible: false, disabled_reason: 'ocr_snapshot_missing')
        expect(options_by_type(described_class.eligibility(receipt: receipt, parent_run: no_ai_run))['finalize_retry']).to include(possible: false, disabled_reason: 'ai_snapshot_missing')
        expect(options_by_type(described_class.eligibility(receipt: receipt, parent_run: no_decision_run))['finalize_retry']).to include(possible: false, disabled_reason: 'finalize_decision_missing')
        expect(options_by_type(described_class.eligibility(receipt: receipt, parent_run: ready_run))['finalize_retry']).to include(possible: true, disabled_reason: nil)
      end
    end
  end

  def parent_ocr_summary
    {
      schema_version: 'receipt_analysis_run_ocr_summary_v1',
      success: true,
      item_count: 1,
      raw_response: 'provider raw',
      secret: 'secret-token'
    }
  end

  def parent_ocr_snapshot
    {
      schema_version: 'receipt_analysis_run_ocr_result_v1',
      success: true,
      raw_text: 'full raw OCR text should not be copied',
      lines: [ 'スマイル', '合計 2998' ],
      candidates: {
        store_name: 'ドラッグストア スマイル',
        total_amount: 2998,
        items: [
          {
            raw_text: 'アメリカ産米',
            line_total: 2998,
            raw_response: 'provider raw'
          }
        ]
      },
      meta: {
        provider: 'azure_document_intelligence',
        model_id: 'prebuilt-receipt',
        raw_response: 'provider raw',
        secret: 'secret-token'
      }
    }
  end

  def parent_ai_summary
    {
      schema_version: 'receipt_analysis_run_ai_result_v1',
      success: true,
      provider: 'openai',
      raw_response: 'provider raw',
      prompt: 'do-not-copy'
    }
  end

  def parent_ai_snapshot
    {
      schema_version: 'receipt_analysis_run_ai_normalized_result_v1',
      success: true,
      error_code: nil,
      needs_review: false,
      review_reasons: [],
      receipt_attributes: {
        store_name: 'ドラッグストア スマイル',
        total_amount: 2998,
        prompt: 'do-not-copy'
      },
      receipt_items_attributes: [
        {
          raw_text: 'アメリカ産米',
          line_total: 2998,
          messages: [ 'do-not-copy' ]
        }
      ],
      meta: {
        provider: 'openai',
        model: 'gpt-test',
        response_body: 'provider raw'
      }
    }
  end

  def parent_finalize_decision_snapshot
    {
      schema_version: 'receipt_analysis_run_finalize_decision_v1',
      strategy: 'ai_success',
      receipt_attributes: {},
      metadata: { reason: 'manual retry' },
      recorded_at: Time.current.iso8601
    }
  end

  def snapshot_json(run)
    JSON.generate(
      {
        ocr_summary: run.ocr_summary,
        ocr_result_snapshot: run.ocr_result_snapshot,
        ai_result_summary: run.ai_result_summary,
        ai_normalized_result_snapshot: run.ai_normalized_result_snapshot,
        metadata: run.metadata
      }
    )
  end

  def parent_state(run)
    run.reload.attributes.slice(
      'status',
      'stage',
      'ocr_summary',
      'ocr_result_snapshot',
      'ai_result_summary',
      'ai_normalized_result_snapshot',
      'metadata'
    )
  end

  def expect_no_analysis_job_enqueued
    expect(ReceiptOcrJob).not_to have_been_enqueued
    expect(ReceiptAiEnrichmentJob).not_to have_been_enqueued
    expect(ReceiptFinalizeJob).not_to have_been_enqueued
  end

  def options_by_type(result)
    result.retry_options.index_by { |option| option[:type] }
  end
end
