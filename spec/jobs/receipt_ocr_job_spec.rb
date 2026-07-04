require 'rails_helper'

RSpec.describe ReceiptOcrJob, type: :job do
  include ActiveJob::TestHelper

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

  describe '.queue_name' do
    it 'receipt_ocr queueを使う' do
      expect(described_class.queue_name).to eq('receipt_ocr')
    end
  end

  describe '#perform' do
    it 'Pipeline親入口だけを呼び、AIが次ならAI Jobをenqueueする' do
      run = create(:receipt_analysis_run)
      allow(ReceiptAnalysisPipeline).to receive(:run_ocr).and_return(pipeline_result(:ai))

      described_class.perform_now(run_id: run.id)

      aggregate_failures do
        expect(ReceiptAnalysisPipeline).to have_received(:run_ocr).with(run)
        expect(ReceiptAiEnrichmentJob).to have_been_enqueued.with(run_id: run.id)
        expect(ReceiptFinalizeJob).not_to have_been_enqueued
      end
    end

    it 'Pipeline Resultのsuccess?ではなくnext_stepで後続Jobをenqueueする' do
      run = create(:receipt_analysis_run)
      result = ReceiptAnalysisPipeline::Result.new(
        ocr_result: { success: false },
        next_step: :ai
      )
      allow(ReceiptAnalysisPipeline).to receive(:run_ocr).and_return(result)

      described_class.perform_now(run_id: run.id)

      aggregate_failures do
        expect(result).not_to be_success
        expect(ReceiptAiEnrichmentJob).to have_been_enqueued.with(run_id: run.id)
        expect(ReceiptFinalizeJob).not_to have_been_enqueued
      end
    end

    it 'finalizeが次ならFinalize Jobをenqueueする' do
      run = create(:receipt_analysis_run)
      allow(ReceiptAnalysisPipeline).to receive(:run_ocr).and_return(pipeline_result(:finalize))

      described_class.perform_now(run_id: run.id)

      aggregate_failures do
        expect(ReceiptAiEnrichmentJob).not_to have_been_enqueued
        expect(ReceiptFinalizeJob).to have_been_enqueued.with(run_id: run.id)
      end
    end

    it 'skippedなら後続Jobをenqueueしない' do
      run = create(:receipt_analysis_run)
      allow(ReceiptAnalysisPipeline).to receive(:run_ocr).and_return(pipeline_result(:skipped, skip_reason: :terminal_run))

      described_class.perform_now(run_id: run.id)

      aggregate_failures do
        expect(ReceiptAiEnrichmentJob).not_to have_been_enqueued
        expect(ReceiptFinalizeJob).not_to have_been_enqueued
      end
    end

    it 'terminal runでは追加enqueueしない' do
      run = create(:receipt_analysis_run, :succeeded)

      described_class.perform_now(run_id: run.id)

      aggregate_failures do
        expect(ReceiptAiEnrichmentJob).not_to have_been_enqueued
        expect(ReceiptFinalizeJob).not_to have_been_enqueued
      end
    end

    it '存在しないrunは安全にdiscardする' do
      allow(ReceiptAnalysisPipeline).to receive(:run_ocr)

      expect do
        described_class.perform_now(run_id: -1)
      end.not_to raise_error

      expect(ReceiptAnalysisPipeline).not_to have_received(:run_ocr)
    end

    it 'run_id keyword以外の呼び出しは受け付けない' do
      run = create(:receipt_analysis_run)

      expect { described_class.perform_now(run.id) }.to raise_error(ArgumentError)
    end

    it 'Pipeline内の例外時はrun failedになり例外を再raiseする' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      allow(ReceiptOcrService).to receive(:call).and_raise(StandardError, 'ocr exploded')

      expect do
        described_class.perform_now(run_id: run.id)
      end.to raise_error(StandardError, 'ocr exploded')

      aggregate_failures do
        expect(run.reload.status).to eq('failed')
        expect(run.error_stage).to eq('ocr')
        expect(run.error_code).to eq('unexpected_error')
        expect(ReceiptAiEnrichmentJob).not_to have_been_enqueued
        expect(ReceiptFinalizeJob).not_to have_been_enqueued
      end
    end

    it '実行前にOCR上限が引き下げ済みならproviderを呼ばずrunをfailedにする' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      create(:usage_counter, user: receipt.user, key: 'ocr_jobs_per_day', used_count: 2)
      create(:user_limit_override, user: receipt.user, key: 'ocr_jobs_per_day', value: { 'value' => 1 })
      allow(ReceiptOcrService).to receive(:call)

      described_class.perform_now(run_id: run.id)

      aggregate_failures do
        expect(ReceiptOcrService).not_to have_received(:call)
        expect(run.reload.status).to eq('failed')
        expect(run.error_stage).to eq('ocr')
        expect(run.error_code).to eq('usage_limit_exceeded')
        expect(receipt.reload.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('usage_limit_exceeded')
        expect(ReceiptAiEnrichmentJob).not_to have_been_enqueued
        expect(ReceiptFinalizeJob).not_to have_been_enqueued
      end
    end

    it 'guest OCR上限超過状態ではproviderを呼ばずrunをfailedにする' do
      guest = create(:user, guest: true)
      receipt = create(:receipt, :processing, :with_image, user: guest)
      run = create(:receipt_analysis_run, receipt:)
      create(:usage_counter, user: guest, key: 'ocr_jobs_per_day', used_count: 6)
      allow(ReceiptOcrService).to receive(:call)

      described_class.perform_now(run_id: run.id)

      aggregate_failures do
        expect(ReceiptOcrService).not_to have_received(:call)
        expect(run.reload.status).to eq('failed')
        expect(run.error_stage).to eq('ocr')
        expect(run.error_code).to eq('usage_limit_exceeded')
        expect(receipt.reload.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('usage_limit_exceeded')
        expect(ReceiptAiEnrichmentJob).not_to have_been_enqueued
        expect(ReceiptFinalizeJob).not_to have_been_enqueued
        expect(UsageCounter.find_by!(user: guest, key: 'ocr_jobs_per_day').used_count).to eq(6)
      end
    end

    it 'OCR停止中の既存runはproviderとOCR counterを使わずfinalizeへ進める' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      create(:system_setting, key: 'operations.ocr_enabled', value: SystemSettings.stored_value(false))
      allow(ReceiptOcrService).to receive(:call)

      described_class.perform_now(run_id: run.id)

      aggregate_failures do
        expect(ReceiptOcrService).not_to have_received(:call)
        expect(run.reload.metadata.dig('finalize_decision', 'error_code')).to eq('ocr_disabled')
        expect(run.ocr_result_snapshot).to include('error_code' => 'ocr_disabled')
        expect(UsageCounter.where(user: receipt.user, key: 'ocr_jobs_per_day')).to be_empty
        expect(ReceiptAiEnrichmentJob).not_to have_been_enqueued
        expect(ReceiptFinalizeJob).to have_been_enqueued.with(run_id: run.id)
      end
    end
  end

  private

  def pipeline_result(next_step, skip_reason: nil)
    ReceiptAnalysisPipeline::Result.new(next_step: next_step, skip_reason: skip_reason)
  end
end
