require 'rails_helper'

RSpec.describe ReceiptAnalysisJob, type: :job do
  describe '.queue_name' do
    it 'receipt_analysis queueを使う' do
      expect(described_class.queue_name).to eq('receipt_analysis')
    end
  end

  describe '#perform' do
    it 'processing receiptだけReceiptAnalysisServiceを実行する' do
      receipt = create(:receipt, :processing, :with_image)

      allow(ReceiptAnalysisService).to receive(:call)

      described_class.perform_now(receipt.id)

      expect(ReceiptAnalysisService).to have_received(:call).with(receipt)
    end

    it 'processing以外のreceiptはskipする' do
      receipt = create(:receipt, :completed)

      allow(ReceiptAnalysisService).to receive(:call)

      described_class.perform_now(receipt.id)

      expect(ReceiptAnalysisService).not_to have_received(:call)
    end

    it '存在しないreceiptは安全にdiscardする' do
      allow(ReceiptAnalysisService).to receive(:call)

      expect do
        described_class.perform_now(-1)
      end.not_to raise_error

      expect(ReceiptAnalysisService).not_to have_received(:call)
    end
  end
end
