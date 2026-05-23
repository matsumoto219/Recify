require 'rails_helper'

RSpec.describe ReceiptFinalizeJob, type: :job do
  describe '.queue_name' do
    it 'receipt_finalize queueを使う' do
      expect(described_class.queue_name).to eq('receipt_finalize')
    end
  end

  describe '#perform' do
    it 'Pipeline親入口だけを呼ぶ' do
      run = create(:receipt_analysis_run)
      allow(ReceiptAnalysisPipeline).to receive(:run_finalize)

      described_class.perform_now(run_id: run.id)

      expect(ReceiptAnalysisPipeline).to have_received(:run_finalize).with(run)
    end

    it '存在しないrunは安全にdiscardする' do
      allow(ReceiptAnalysisPipeline).to receive(:run_finalize)

      expect do
        described_class.perform_now(run_id: -1)
      end.not_to raise_error

      expect(ReceiptAnalysisPipeline).not_to have_received(:run_finalize)
    end

    it 'run_id keyword以外の呼び出しは受け付けない' do
      run = create(:receipt_analysis_run)

      expect { described_class.perform_now(run.id) }.to raise_error(ArgumentError)
    end
  end
end
