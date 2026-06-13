require 'rails_helper'

RSpec.describe ReceiptAiEnrichmentJob, type: :job do
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
    it 'receipt_ai queueを使う' do
      expect(described_class.queue_name).to eq('receipt_ai')
    end
  end

  describe '#perform' do
    it 'Pipeline親入口だけを呼び、finalizeが次ならFinalize Jobをenqueueする' do
      run = create(:receipt_analysis_run)
      allow(ReceiptAnalysisPipeline).to receive(:run_ai).and_return(pipeline_result(:finalize))

      described_class.perform_now(run_id: run.id)

      aggregate_failures do
        expect(ReceiptAnalysisPipeline).to have_received(:run_ai).with(run)
        expect(ReceiptFinalizeJob).to have_been_enqueued.with(run_id: run.id)
      end
    end

    it 'skippedなら後続Jobをenqueueしない' do
      run = create(:receipt_analysis_run)
      allow(ReceiptAnalysisPipeline).to receive(:run_ai).and_return(pipeline_result(:skipped, skip_reason: :terminal_run))

      described_class.perform_now(run_id: run.id)

      expect(ReceiptFinalizeJob).not_to have_been_enqueued
    end

    it 'terminal runでは追加enqueueしない' do
      run = create(:receipt_analysis_run, :succeeded)

      described_class.perform_now(run_id: run.id)

      expect(ReceiptFinalizeJob).not_to have_been_enqueued
    end

    it '存在しないrunは安全にdiscardする' do
      allow(ReceiptAnalysisPipeline).to receive(:run_ai)

      expect do
        described_class.perform_now(run_id: -1)
      end.not_to raise_error

      expect(ReceiptAnalysisPipeline).not_to have_received(:run_ai)
    end

    it 'run_id keyword以外の呼び出しは受け付けない' do
      run = create(:receipt_analysis_run)

      expect { described_class.perform_now(run.id) }.to raise_error(ArgumentError)
    end

    it 'AI provider call直前で上限到達ならproviderを呼ばずrunをfailedにする' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(
        :receipt_analysis_run,
        receipt: receipt,
        stage: 'ai',
        ocr_result_snapshot: {
          'success' => true,
          'lines' => [ 'テストストア', '合計 1000' ],
          'candidates' => { 'store_name' => 'テストストア', 'total_amount' => 1000 },
          'meta' => {}
        }
      )
      create(:usage_counter, user: receipt.user, key: 'ai_jobs_per_day', used_count: 50)
      allow(ExternalServices).to receive(:down?).with(:ai).and_return(false)
      allow(ReceiptAiEnrichmentService).to receive(:call)

      described_class.perform_now(run_id: run.id)

      aggregate_failures do
        expect(ReceiptAiEnrichmentService).not_to have_received(:call)
        expect(run.reload.status).to eq('failed')
        expect(run.error_stage).to eq('ai')
        expect(run.error_code).to eq('usage_limit_exceeded')
        expect(receipt.reload.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('usage_limit_exceeded')
        expect(ReceiptFinalizeJob).not_to have_been_enqueued
        expect(UsageCounter.find_by!(user: receipt.user, key: 'ai_jobs_per_day').used_count).to eq(50)
      end
    end

    it 'guest AI上限到達時はproviderを呼ばずrunをfailedにする' do
      guest = create(:user, guest: true)
      receipt = create(:receipt, :processing, :with_image, user: guest)
      run = create(
        :receipt_analysis_run,
        receipt: receipt,
        stage: 'ai',
        ocr_result_snapshot: {
          'success' => true,
          'lines' => [ 'テストストア', '合計 1000' ],
          'candidates' => { 'store_name' => 'テストストア', 'total_amount' => 1000 },
          'meta' => {}
        }
      )
      create(:usage_counter, user: guest, key: 'ai_jobs_per_day', used_count: 5)
      allow(ExternalServices).to receive(:down?).with(:ai).and_return(false)
      allow(ReceiptAiEnrichmentService).to receive(:call)

      described_class.perform_now(run_id: run.id)

      aggregate_failures do
        expect(ReceiptAiEnrichmentService).not_to have_received(:call)
        expect(run.reload.status).to eq('failed')
        expect(run.error_stage).to eq('ai')
        expect(run.error_code).to eq('usage_limit_exceeded')
        expect(receipt.reload.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('usage_limit_exceeded')
        expect(ReceiptFinalizeJob).not_to have_been_enqueued
        expect(UsageCounter.find_by!(user: guest, key: 'ai_jobs_per_day').used_count).to eq(5)
      end
    end

    it 'AI停止中の既存runはAI APIとcounterを使わずfinalizeへ進める' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(
        :receipt_analysis_run,
        receipt: receipt,
        stage: 'ai',
        ocr_result_snapshot: {
          'success' => true,
          'lines' => [ 'テストストア', '合計 1000' ],
          'candidates' => { 'store_name' => 'テストストア', 'total_amount' => 1000 },
          'meta' => {}
        }
      )
      create(:system_setting, key: 'operations.ai_enabled', value: SystemSettings.stored_value(false))
      allow(ReceiptAiEnrichmentService).to receive(:call)

      described_class.perform_now(run_id: run.id)

      aggregate_failures do
        expect(ReceiptAiEnrichmentService).not_to have_received(:call)
        expect(run.reload.metadata.dig('finalize_decision', 'error_code')).to eq('ai_unavailable')
        expect(UsageCounter.where(user: receipt.user, key: 'ai_jobs_per_day')).to be_empty
        expect(ReceiptFinalizeJob).to have_been_enqueued.with(run_id: run.id)
      end
    end
  end

  private

  def pipeline_result(next_step, skip_reason: nil)
    ReceiptAnalysisPipeline::Result.new(next_step: next_step, skip_reason: skip_reason)
  end
end
