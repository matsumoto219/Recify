require 'rails_helper'

RSpec.describe ReceiptAnalysisJob, type: :job do
  describe '.queue_name' do
    it 'receipt_analysis queueを使う' do
      expect(described_class.queue_name).to eq('receipt_analysis')
    end
  end

  describe '#perform' do
    it 'runを取得してReceiptAnalysisPipelineへ委譲する' do
      run = create(:receipt_analysis_run)

      allow(ReceiptAnalysisPipeline).to receive(:run_current_pipeline)

      described_class.perform_now(run_id: run.id)

      expect(ReceiptAnalysisPipeline).to have_received(:run_current_pipeline).with(run)
    end

    it '存在しないrunは安全にdiscardする' do
      allow(ReceiptAnalysisPipeline).to receive(:run_current_pipeline)

      expect do
        described_class.perform_now(run_id: -1)
      end.not_to raise_error

      expect(ReceiptAnalysisPipeline).not_to have_received(:run_current_pipeline)
    end
  end
end
