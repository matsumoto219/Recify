require 'rails_helper'

RSpec.describe ReceiptAnalysisPipeline do
  def successful_ocr_result
    {
      success: true,
      raw_text: "テストストア\nコーヒー 180\n合計 180\n現金",
      lines: [
        'テストストア',
        'コーヒー 180',
        '合計 180',
        '現金'
      ],
      candidates: {
        store_name: 'テストストア',
        total_amount: 180,
        country_region: 'JPN',
        payment_method_text: '現金',
        items: [
          {
            raw_text: 'コーヒー',
            price: 180,
            quantity: 1,
            line_total: 180,
            confidence: 0.95
          }
        ],
        payments: [
          { method: 'Cash', amount: 180 }
        ],
        tax_details: []
      },
      meta: {
        provider: 'azure_document_intelligence',
        model_id: 'prebuilt-receipt'
      }
    }
  end

  describe '.run_current_pipeline' do
    it 'processing receiptだけReceiptAnalysisServiceを実行する' do
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

      described_class.run_current_pipeline(run)
      run.reload

      aggregate_failures do
        expect(ReceiptAnalysisService).to have_received(:call).with(receipt, run: run)
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

    it 'OCR失敗でもPipelineが正常完走した場合はrunをsucceededにする' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      ocr_result = {
        success: false,
        error_code: 'ocr_timeout',
        lines: [],
        meta: {
          provider: 'azure_document_intelligence',
          model_id: 'prebuilt-receipt'
        }
      }

      allow(ReceiptOcrService).to receive(:call).and_return(ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call)

      described_class.run_current_pipeline(run)

      aggregate_failures do
        expect(receipt.reload.status).to eq('failed')
        expect(run.reload.status).to eq('succeeded')
        expect(run.stage).to eq('completed')
        expect(run.ocr_summary).to include('success' => false, 'error_code' => 'ocr_timeout')
        expect(run.ai_input_snapshot).to eq({})
        expect(run.ai_result_summary).to eq({})
        expect(run.final_result_summary).to include(
          'receipt_status' => 'failed',
          'processing_error_code' => 'ocr_timeout'
        )
        expect(ReceiptAiEnrichmentService).not_to have_received(:call)
      end
    end

    it 'AI失敗fallbackでもPipelineが正常完走した場合はrunをsucceededにする' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      ai_input = {
        filtered_content: "テストストア\nコーヒー 180",
        items: [ { raw_text: 'コーヒー', line_total: 180 } ],
        meta: { ocr_provider: 'azure_document_intelligence', ocr_model: 'prebuilt-receipt' }
      }
      failed_ai_result = {
        success: false,
        error_code: 'ai_primary_failed',
        receipt_attributes: {},
        receipt_items_attributes: [],
        meta: {
          primary_provider: 'openai',
          fallback_used: false,
          primary_error_code: 'ai_primary_failed'
        }
      }

      allow(ReceiptOcrService).to receive(:call).and_return(successful_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call) do |_ocr_result, ai_name_completion_enabled:, capture_input:|
        capture_input.call(ai_input)
        failed_ai_result
      end

      described_class.run_current_pipeline(run)

      aggregate_failures do
        expect(receipt.reload.status).to eq('review_needed')
        expect(receipt.processing_error_code).to eq('ai_primary_failed')
        expect(run.reload.status).to eq('succeeded')
        expect(run.stage).to eq('completed')
        expect(run.ai_input_snapshot).to include('filtered_content' => "テストストア\nコーヒー 180")
        expect(run.ai_result_summary).to include(
          'success' => false,
          'error_code' => 'ai_primary_failed',
          'provider' => 'openai'
        )
        expect(run.final_result_summary).to include(
          'receipt_status' => 'review_needed',
          'processing_error_code' => 'ai_primary_failed'
        )
      end
    end

    it 'processing以外のreceiptはskipしactive runをcancelする' do
      receipt = create(:receipt, :completed)
      run = create(:receipt_analysis_run, receipt:)

      allow(ReceiptAnalysisService).to receive(:call)

      described_class.run_current_pipeline(run)

      aggregate_failures do
        expect(ReceiptAnalysisService).not_to have_received(:call)
        expect(run.reload.status).to eq('canceled')
      end
    end

    it 'terminal runは再処理しない' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, :succeeded, receipt:)

      allow(ReceiptAnalysisService).to receive(:call)

      described_class.run_current_pipeline(run)

      aggregate_failures do
        expect(ReceiptAnalysisService).not_to have_received(:call)
        expect(run.reload.status).to eq('succeeded')
      end
    end

    it '例外時はrunをfailedにして例外を再raiseする' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)

      allow(ReceiptAnalysisService).to receive(:call).and_raise(
        ReceiptAnalysisService::AnalysisError.new('unexpected_error', 'boom')
      )

      expect do
        described_class.run_current_pipeline(run)
      end.to raise_error(ReceiptAnalysisService::AnalysisError, 'boom')

      aggregate_failures do
        expect(run.reload.status).to eq('failed')
        expect(run.stage).to eq('ocr')
        expect(run.error_stage).to eq('ocr')
        expect(run.error_code).to eq('unexpected_error')
        expect(run.error_message).to eq('boom')
      end
    end
  end
end
