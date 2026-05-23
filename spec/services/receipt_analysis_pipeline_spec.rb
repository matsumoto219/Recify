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
        model_id: 'prebuilt-receipt',
        raw_response: { secret: 'do-not-store' }
      },
      image: 'do-not-store'
    }
  end

  def successful_ai_result
    {
      success: true,
      needs_review: false,
      receipt_attributes: {
        store_name: 'AIテストストア',
        payment_method: 'cash'
      },
      receipt_items_attributes: [
        {
          index: 0,
          suggested_name: 'コーヒー',
          category: 'drink',
          line_total: 180,
          needs_review: false,
          confidence: 0.95
        }
      ]
    }
  end

  def amount_result(inconsistencies:, blocking_inconsistencies:, warning_inconsistencies:)
    {
      resolved: {
        total: 180,
        subtotal: 164,
        tax: 16,
        tax_rate: BigDecimal('0.1')
      },
      computed: {
        items: []
      },
      tax_details: [],
      inconsistencies: inconsistencies,
      blocking_inconsistencies: blocking_inconsistencies,
      warning_inconsistencies: warning_inconsistencies,
      mismatch_codes: inconsistencies.filter_map { |inconsistency| Amounts::MismatchCodes.code(inconsistency) },
      blocking_mismatch_codes: blocking_inconsistencies.filter_map { |inconsistency| Amounts::MismatchCodes.code(inconsistency) },
      warning_mismatch_codes: warning_inconsistencies.filter_map { |inconsistency| Amounts::MismatchCodes.code(inconsistency) },
      warning_reasons: warning_inconsistencies.map(&:to_s),
      mismatch_messages: [],
      needs_review: blocking_inconsistencies.any?
    }
  end

  def finalize_decision(strategy, **attributes)
    ReceiptAnalysisPipeline::FinalizeDecision.new(
      {
        finalize_strategy: strategy.to_s,
        error_code: nil,
        error_message: nil,
        receipt_attributes: {},
        ocr_result: nil,
        ai_result: nil,
        metadata: {}
      }.merge(attributes)
    )
  end

  describe '.run_current_pipeline' do
    it 'processing receiptだけReceiptAnalysisServiceを実行する' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)

      allow(ReceiptOcrService).to receive(:call).and_return(successful_ocr_result)
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
        expect(ReceiptOcrService).to have_received(:call).once
        expect(ReceiptAnalysisService).to have_received(:call).with(receipt, run: run, ocr_result: successful_ocr_result)
        expect(run.status).to eq('succeeded')
        expect(run.stage).to eq('completed')
        expect(run.started_at).to be_present
        expect(run.ocr_started_at).to be_present
        expect(run.finished_at).to be_present
        expect(run.ocr_summary).to include(
          'success' => true,
          'provider' => 'azure_document_intelligence',
          'model' => 'prebuilt-receipt'
        )
        expect(run.ocr_result_snapshot).to include(
          'schema_version' => 'receipt_analysis_run_ocr_result_v1',
          'success' => true
        )
        expect(run.ocr_result_snapshot).not_to have_key('raw_text')
        expect(run.ocr_result_snapshot.to_json).not_to include('do-not-store')
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
        expect(ReceiptOcrService).to have_received(:call).once
        expect(receipt.reload.status).to eq('failed')
        expect(run.reload.status).to eq('succeeded')
        expect(run.stage).to eq('completed')
        expect(run.ocr_summary).to include('success' => false, 'error_code' => 'ocr_timeout')
        expect(run.ocr_result_snapshot).to include('success' => false, 'error_code' => 'ocr_timeout')
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
        prompt: '保存しないprompt全文',
        messages: [ '保存しないmessages' ],
        meta: {
          primary_provider: 'openai',
          fallback_used: false,
          primary_error_code: 'ai_primary_failed',
          response_body: '保存しないraw response',
          api_key: '保存しないapi key'
        }
      }

      allow(ReceiptOcrService).to receive(:call).and_return(successful_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call) do |_ocr_result, ai_name_completion_enabled:, capture_input:|
        capture_input.call(ai_input)
        failed_ai_result
      end

      described_class.run_current_pipeline(run)

      aggregate_failures do
        expect(ReceiptOcrService).to have_received(:call).once
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
        expect(run.ai_normalized_result_snapshot).to include(
          'schema_version' => 'receipt_analysis_run_ai_normalized_result_v1',
          'success' => false,
          'error_code' => 'ai_primary_failed'
        )
        expect(run.ai_normalized_result_snapshot.to_json).not_to include(
          '保存しないprompt全文',
          '保存しないmessages',
          '保存しないraw response',
          '保存しないapi key'
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
        expect(run.stage).to eq('ocr_validation')
        expect(run.error_stage).to eq('ocr_validation')
        expect(run.error_code).to eq('unexpected_error')
        expect(run.error_message).to eq('boom')
      end
    end
  end

  describe '.run_ai' do
    it 'AI実行結果とAI input/result/normalized snapshotを保存する' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      ai_input = {
        filtered_content: "テストストア\nコーヒー 180",
        prompt: '保存しないprompt全文',
        raw_response: '保存しないraw response',
        messages: [ '保存しないmessages' ],
        items: [ { raw_text: 'コーヒー', line_total: 180 } ],
        meta: { ocr_provider: 'azure_document_intelligence', ocr_model: 'prebuilt-receipt' }
      }
      ai_result = {
        success: true,
        needs_review: false,
        receipt_attributes: {
          payment_method: 'cash'
        },
        receipt_items_attributes: [
          {
            index: 0,
            suggested_name: 'コーヒー',
            category: 'drink',
            line_total: 180
          }
        ],
        meta: {
          provider: 'openai',
          model: 'gpt-test',
          response_body: '保存しないAI raw response',
          api_key: '保存しないapi key'
        }
      }

      allow(ReceiptAiEnrichmentService).to receive(:call) do |_ocr_result, ai_name_completion_enabled:, capture_input:|
        expect(ai_name_completion_enabled).to eq(true)
        capture_input.call(ai_input)
        ai_result
      end

      result = described_class.run_ai(
        run: run,
        ocr_result: successful_ocr_result,
        ai_name_completion_enabled: true
      )
      run.reload

      aggregate_failures do
        expect(result.ai_result).to eq(ai_result)
        expect(ReceiptAiEnrichmentService).to have_received(:call).once
        expect(run.stage).to eq('finalize')
        expect(run.ai_input_snapshot).to include(
          'schema_version' => 'receipt_analysis_run_ai_input_v1',
          'filtered_content' => "テストストア\nコーヒー 180"
        )
        expect(run.ai_result_summary).to include(
          'schema_version' => 'receipt_analysis_run_ai_result_v1',
          'success' => true,
          'provider' => 'openai',
          'model' => 'gpt-test'
        )
        expect(run.ai_normalized_result_snapshot).to include(
          'schema_version' => 'receipt_analysis_run_ai_normalized_result_v1',
          'success' => true
        )
        expect(run.ai_normalized_result_snapshot.dig('receipt_attributes', 'payment_method')).to eq('cash')
        expect(run.ai_input_snapshot.to_json).not_to include(
          '保存しないprompt全文',
          '保存しないraw response',
          '保存しないmessages'
        )
        expect(run.ai_normalized_result_snapshot.to_json).not_to include(
          '保存しないAI raw response',
          '保存しないapi key'
        )
      end
    end
  end

  describe '.finalize' do
    it 'ai_success decisionを保存しcompletedにできる' do
      receipt = create(:receipt, :processing, :with_image)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [],
          blocking_inconsistencies: [],
          warning_inconsistencies: []
        )
      )

      result = described_class.finalize(
        receipt: receipt,
        decision: finalize_decision(
          :ai_success,
          ocr_result: successful_ocr_result,
          ai_result: successful_ai_result
        )
      )

      receipt.reload

      aggregate_failures do
        expect(result).to eq(receipt)
        expect(receipt.status).to eq('completed')
        expect(receipt.processing_error_code).to be_nil
        expect(receipt.review_reasons).to be_blank
        expect(receipt.total_amount).to eq(180)
        expect(receipt.subtotal_amount).to eq(164)
        expect(receipt.tax_amount).to eq(16)
        expect(receipt.receipt_items.pluck(:suggested_name, :category)).to include([ 'コーヒー', 'drink' ])
      end
    end

    it 'ai_success decisionのwarning mismatchはcompletedのままreview_reasonsに残す' do
      receipt = create(:receipt, :processing, :with_image)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [:price_tax_inclusion_uncertain],
          blocking_inconsistencies: [],
          warning_inconsistencies: [:price_tax_inclusion_uncertain]
        )
      )

      described_class.finalize(
        receipt: receipt,
        decision: finalize_decision(
          :ai_success,
          ocr_result: successful_ocr_result,
          ai_result: successful_ai_result
        )
      )

      aggregate_failures do
        expect(receipt.reload.status).to eq('completed')
        expect(receipt.review_reasons).to eq([ 'price_tax_inclusion_uncertain' ])
      end
    end

    it 'ai_success decisionのblocking mismatchはreview_neededにする' do
      receipt = create(:receipt, :processing, :with_image)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [:tax_detail_mismatch],
          blocking_inconsistencies: [:tax_detail_mismatch],
          warning_inconsistencies: []
        )
      )

      described_class.finalize(
        receipt: receipt,
        decision: finalize_decision(
          :ai_success,
          ocr_result: successful_ocr_result,
          ai_result: successful_ai_result
        )
      )

      aggregate_failures do
        expect(receipt.reload.status).to eq('review_needed')
        expect(receipt.review_reasons).to eq([ 'tax_detail_mismatch' ])
      end
    end

    it 'ocr_only decisionはreview_needed固定で保存する' do
      receipt = create(:receipt, :processing, :with_image)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [],
          blocking_inconsistencies: [],
          warning_inconsistencies: []
        )
      )

      described_class.finalize(
        receipt: receipt,
        decision: finalize_decision(:ocr_only, ocr_result: successful_ocr_result)
      )

      aggregate_failures do
        expect(receipt.reload.status).to eq('review_needed')
        expect(receipt.processing_error_code).to be_nil
      end
    end

    it 'ai_fallback decisionはreview_needed固定でerror_codeを保存する' do
      receipt = create(:receipt, :processing, :with_image)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [],
          blocking_inconsistencies: [],
          warning_inconsistencies: []
        )
      )

      described_class.finalize(
        receipt: receipt,
        decision: finalize_decision(
          :ai_fallback,
          ocr_result: successful_ocr_result,
          error_code: 'ai_unavailable',
          error_message: 'AI補完に失敗したためOCR結果で保存しました'
        )
      )

      aggregate_failures do
        expect(receipt.reload.status).to eq('review_needed')
        expect(receipt.processing_error_code).to eq('ai_unavailable')
        expect(receipt.processing_error_message).to eq('AI補完に失敗したためOCR結果で保存しました')
      end
    end

    it 'fail_receipt decisionはerror mapperを通してfailedにする' do
      receipt = create(:receipt, :processing, :with_image)

      described_class.finalize(
        receipt: receipt,
        decision: finalize_decision(
          :fail_receipt,
          error_code: 'ocr_timeout',
          error_message: 'timeout'
        )
      )

      aggregate_failures do
        expect(receipt.reload.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('ocr_timeout')
        expect(receipt.processing_error_message).to eq('timeout')
        expect(receipt.review_reasons).to eq([])
        expect(receipt.ocr_completed_at).to be_present
      end
    end

    it 'unsupported_countryの追加属性を維持する' do
      receipt = create(:receipt, :processing, :with_image)

      described_class.finalize(
        receipt: receipt,
        decision: finalize_decision(
          :fail_receipt,
          error_code: 'unsupported_country',
          error_message: 'country_region=USA',
          receipt_attributes: { country_region: 'USA' }
        )
      )

      aggregate_failures do
        expect(receipt.reload.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('unsupported_country')
        expect(receipt.country_region).to eq('USA')
      end
    end
  end
end
