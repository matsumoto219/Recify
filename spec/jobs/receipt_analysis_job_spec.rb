require 'rails_helper'

RSpec.describe ReceiptAnalysisJob, type: :job do
  describe '.queue_name' do
    it 'receipt_analysis queueを使う' do
      expect(described_class.queue_name).to eq('receipt_analysis')
    end
  end

  describe '#perform' do
    it 'run_id経路でprocessing receiptだけReceiptAnalysisServiceを実行する' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)

      allow(ReceiptAnalysisService).to receive(:call) do |target_receipt|
        target_receipt.update!(
          status: 'review_needed',
          processing_error_code: 'ai_unavailable',
          review_reasons: [ 'ocr_low_confidence' ]
        )
        target_receipt.receipt_items.create!(raw_text: 'コーヒー', line_total: 180)
      end

      described_class.perform_now(run_id: run.id)
      run.reload

      aggregate_failures do
        expect(ReceiptAnalysisService).to have_received(:call).with(receipt)
        expect(run.status).to eq('succeeded')
        expect(run.stage).to eq('completed')
        expect(run.started_at).to be_present
        expect(run.ocr_started_at).to be_present
        expect(run.finished_at).to be_present
        expect(run.final_result_summary).to include(
          'receipt_status' => 'review_needed',
          'processing_error_code' => 'ai_unavailable',
          'review_reasons' => [ 'ocr_low_confidence' ],
          'item_count' => 1
        )
      end
    end

    it '旧receipt_id経路も一時的に実行できる' do
      receipt = create(:receipt, :processing, :with_image)

      allow(ReceiptAnalysisService).to receive(:call) do |target_receipt|
        target_receipt.update!(status: 'completed')
      end

      described_class.perform_now(receipt.id)

      run = receipt.receipt_analysis_runs.sole

      aggregate_failures do
        expect(ReceiptAnalysisService).to have_received(:call).with(receipt)
        expect(run.source).to eq('system_retry')
        expect(run.status).to eq('succeeded')
      end
    end

    it 'processing以外のreceiptはskipしactive runをcancelする' do
      receipt = create(:receipt, :completed)
      run = create(:receipt_analysis_run, receipt:)

      allow(ReceiptAnalysisService).to receive(:call)

      described_class.perform_now(run_id: run.id)

      aggregate_failures do
        expect(ReceiptAnalysisService).not_to have_received(:call)
        expect(run.reload.status).to eq('canceled')
      end
    end

    it 'terminal runは再処理しない' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, :succeeded, receipt:)

      allow(ReceiptAnalysisService).to receive(:call)

      described_class.perform_now(run_id: run.id)

      aggregate_failures do
        expect(ReceiptAnalysisService).not_to have_received(:call)
        expect(run.reload.status).to eq('succeeded')
      end
    end

    it 'Job例外時はrunをfailedにして例外を再raiseする' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)

      allow(ReceiptAnalysisService).to receive(:call).and_raise(
        ReceiptAnalysisService::AnalysisError.new('unexpected_error', 'boom')
      )

      expect do
        described_class.perform_now(run_id: run.id)
      end.to raise_error(ReceiptAnalysisService::AnalysisError, 'boom')

      aggregate_failures do
        expect(run.reload.status).to eq('failed')
        expect(run.stage).to eq('ocr')
        expect(run.error_stage).to eq('ocr')
        expect(run.error_code).to eq('unexpected_error')
        expect(run.error_message).to eq('boom')
      end
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
