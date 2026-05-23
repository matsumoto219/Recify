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
  end

  private

  def pipeline_result(next_step, skip_reason: nil)
    ReceiptAnalysisPipeline::Result.new(next_step: next_step, skip_reason: skip_reason)
  end
end
