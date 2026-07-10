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

    it 'terminal runのreplayではreceiptを変更しない' do
      receipt = create(:receipt, store_name: 'Replay Safe', total_amount: 1000, status: 'completed')
      run = create(:receipt_analysis_run, :succeeded, receipt: receipt)

      expect do
        described_class.perform_now(run_id: run.id)
      end.not_to change { receipt.reload.attributes.slice('status', 'store_name', 'total_amount', 'updated_at') }

      expect(run.reload.status).to eq('succeeded')
    end

    it '同じrunのFinalize Jobを再実行しても保存処理は1回だけにする' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      decision = ReceiptAnalysisPipeline::FinalizeDecision.new(
        finalize_strategy: 'fail_receipt',
        error_code: 'ocr_api_error',
        receipt_attributes: {}
      )
      ReceiptAnalysisRuns.record_finalize_decision(run, decision)
      allow(ReceiptAnalysisPipeline).to receive(:finalize).and_call_original

      2.times { described_class.perform_now(run_id: run.id) }

      aggregate_failures do
        expect(ReceiptAnalysisPipeline).to have_received(:finalize).once
        expect(receipt.reload.status).to eq('failed')
        expect(run.reload.status).to eq('succeeded')
      end
    end

    it 'finalize中に負値itemが混じっても通常明細として保存せず失敗にしない' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      ocr_result = {
        success: true,
        lines: [ 'Short Dated Stock -2160', '合計 0' ],
        candidates: {
          store_name: 'テストストア',
          total_amount: 0,
          country_region: 'JPN',
          payment_method_text: '現金',
          items: [ { raw_text: 'Short Dated Stock', line_total: -2160 } ],
          payments: [ { method: 'Cash', amount: 0 } ],
          tax_details: []
        }
      }
      ai_result = {
        success: true,
        needs_review: false,
        receipt_attributes: { payment_method: 'cash' },
        receipt_items_attributes: [
          { index: 0, suggested_name: 'Short Dated Stock', category: 'other', needs_review: false }
        ]
      }
      decision = ReceiptAnalysisPipeline::FinalizeDecision.new(
        finalize_strategy: 'ai_success',
        ocr_result: ocr_result,
        ai_result: ai_result
      )

      ReceiptAnalysisRuns.record_ocr_snapshot(run, ocr_result)
      ReceiptAnalysisRuns.record_ai_normalized_result(run, ai_result)
      ReceiptAnalysisRuns.record_finalize_decision(run, decision)
      allow(ReceiptAmountService).to receive(:call).and_return(
        {
          resolved: { total: 0, subtotal: 0, tax: 0, tax_rate: nil },
          computed: {
            items: [
              { price: -2160, quantity: 1, line_total: -2160 }
            ]
          },
          tax_details: [],
          inconsistencies: [],
          blocking_inconsistencies: [],
          warning_inconsistencies: [],
          mismatch_codes: [],
          blocking_mismatch_codes: [],
          warning_mismatch_codes: [],
          warning_reasons: [],
          mismatch_messages: [],
          needs_review: false
        }
      )

      expect { described_class.perform_now(run_id: run.id) }.not_to raise_error

      aggregate_failures do
        expect(run.reload.status).to eq('succeeded')
        expect(receipt.reload.status).to eq('review_needed')
        expect(receipt.receipt_items).to be_empty
        expect(receipt.review_reasons).to include('adjustment_uncertain')
        expect(receipt.processing_error_code).to be_nil
      end
    end
  end
end
