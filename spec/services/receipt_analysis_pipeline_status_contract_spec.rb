require 'rails_helper'

RSpec.describe 'ReceiptAnalysisPipeline status contract' do
  def successful_ocr_result(overrides = {})
    {
      success: true,
      raw_text: "契約テストストア\nコーヒー 180\n合計 180\n現金",
      lines: [
        '契約テストストア',
        'コーヒー 180',
        '合計 180',
        '現金'
      ],
      candidates: {
        store_name: '契約テストストア',
        total_amount: 180,
        country_region: 'JPN',
        payment_method_text: '現金',
        items: [
          {
            raw_text: 'コーヒー',
            price: 180,
            quantity: 1,
            quantity_unit_code: 'each',
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
        confidence_summary: {
          overall: 0.95,
          items_average: 0.95
        }
      }
    }.deep_merge(overrides)
  end

  def successful_ai_result(suggested_name: 'AI補正コーヒー')
    {
      success: true,
      needs_review: false,
      review_reasons: [],
      receipt_attributes: {
        store_name: 'AI契約テストストア',
        payment_method: 'cash'
      },
      receipt_items_attributes: [
        {
          index: 0,
          suggested_name: suggested_name,
          category: 'drink',
          needs_review: false
        }
      ]
    }
  end

  def failed_ai_result(error_code, meta: {})
    {
      success: false,
      error_code: error_code,
      needs_review: true,
      review_reasons: [ error_code ],
      receipt_attributes: {},
      receipt_items_attributes: [],
      meta: meta
    }
  end

  def failed_ocr_result(error_code)
    {
      success: false,
      error_code: error_code,
      raw_text: '',
      lines: [],
      candidates: {},
      meta: {
        provider: 'azure_document_intelligence',
        model_id: 'prebuilt-receipt'
      }
    }
  end

  def no_amount_mismatch_result
    {
      resolved: {
        total: 180,
        subtotal: 180,
        tax: 0,
        tax_rate: BigDecimal('0')
      },
      computed: {
        items: []
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
  end

  def build_processing_run
    receipt = create(:receipt, :processing, :with_image)
    run = create(:receipt_analysis_run, receipt: receipt)

    [ receipt, run ]
  end

  def stub_services_available
    allow(ExternalServices).to receive(:snapshot).and_call_original
    allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return(state: 'ok')
    allow(ExternalServices).to receive(:snapshot).with(:ai).and_return(state: 'ok')
  end

  def stub_amount_service(amount_result = no_amount_mismatch_result)
    allow(ReceiptAmountService).to receive(:call).and_return(amount_result)
  end

  def record_ocr_snapshot(run, ocr_result = successful_ocr_result)
    ReceiptAnalysisRuns.record_ocr_snapshot(run, ocr_result)
  end

  def run_ai_and_finalize(ai_result, amount_result: no_amount_mismatch_result)
    receipt, run = build_processing_run
    record_ocr_snapshot(run)
    stub_services_available
    stub_amount_service(amount_result)
    allow(ReceiptAiEnrichmentService).to receive(:call).and_return(ai_result)

    ai_stage = ReceiptAnalysisPipeline.run_ai(run)
    finalize_stage = ReceiptAnalysisPipeline.run_finalize(run)

    [ receipt.reload, run.reload, ai_stage, finalize_stage ]
  end

  def run_ocr_and_finalize(ocr_result)
    receipt, run = build_processing_run
    stub_services_available
    allow(ReceiptOcrService).to receive(:call).and_return(ocr_result)
    allow(ReceiptAiEnrichmentService).to receive(:call)

    ocr_stage = nil
    finalize_stage = nil

    expect do
      ocr_stage = ReceiptAnalysisPipeline.run_ocr(run)
      finalize_stage = ReceiptAnalysisPipeline.run_finalize(run)
    end.not_to change(AuditLog, :count)

    [ receipt.reload, run.reload, ocr_stage, finalize_stage ]
  end

  def expect_ai_fallback_contract(error_code, ai_result: failed_ai_result(error_code), processing_error_message: nil)
    receipt, run, ai_stage, finalize_stage = run_ai_and_finalize(ai_result)

    aggregate_failures(error_code) do
      expect(ai_stage.next_step).to eq(:finalize)
      expect(ai_stage.finalize_decision.finalize_strategy).to eq('ai_fallback')
      expect(ai_stage.finalize_decision.error_code).to eq(error_code)
      expect(finalize_stage.next_step).to eq(:done)
      expect(receipt.status).to eq('review_needed')
      expect(receipt.processing_error_code).to eq(error_code)
      expect(receipt.processing_error_message).to eq(processing_error_message)
      expect(receipt.review_reasons).to eq([])
      expect(run.status).to eq('succeeded')
      expect(run.final_result_summary).to include(
        'receipt_status' => 'review_needed',
        'processing_error_code' => error_code
      )
      expect(receipt.receipt_items.sole).to have_attributes(
        raw_text: 'コーヒー',
        confirmed_name: nil
      )
    end
  end

  def expect_ocr_failure_contract(error_code, ocr_result: failed_ocr_result(error_code), expected_security_event_change: 0)
    security_event_scope = SecurityEvent.all
    receipt = nil
    run = nil
    ocr_stage = nil
    finalize_stage = nil

    expect do
      receipt, run, ocr_stage, finalize_stage = run_ocr_and_finalize(ocr_result)
    end.to change(security_event_scope, :count).by(expected_security_event_change)

    aggregate_failures(error_code) do
      expect(ocr_stage.next_step).to eq(:finalize)
      expect(ocr_stage.finalize_decision.finalize_strategy).to eq('fail_receipt')
      expect(ocr_stage.finalize_decision.error_code).to eq(error_code)
      expect(finalize_stage.next_step).to eq(:done)
      expect(receipt.status).to eq('failed')
      expect(receipt.processing_error_code).to eq(error_code)
      expect(receipt.review_reasons).to eq([])
      expect(receipt.receipt_items).to be_empty
      expect(run.status).to eq('succeeded')
      expect(run.final_result_summary).to include(
        'receipt_status' => 'failed',
        'processing_error_code' => error_code
      )
      expect(ReceiptAiEnrichmentService).not_to have_received(:call)
    end
  end

  describe 'AI status contract' do
    it 'AI成功はcompletedへ進み、OCR raw_textを保持しconfirmed_nameを自動設定しない' do
      receipt, run, ai_stage, finalize_stage = run_ai_and_finalize(successful_ai_result)
      item = receipt.receipt_items.sole

      aggregate_failures do
        expect(ai_stage.finalize_decision.finalize_strategy).to eq('ai_success')
        expect(finalize_stage.next_step).to eq(:done)
        expect(receipt.status).to eq('completed')
        expect(receipt.processing_error_code).to be_nil
        expect(receipt.processing_error_message).to be_nil
        expect(receipt.review_reasons).to eq([])
        expect(item.raw_text).to eq('コーヒー')
        expect(item.suggested_name).to eq('AI補正コーヒー')
        expect(item.confirmed_name).to be_nil
        expect(run.status).to eq('succeeded')
        expect(run.final_result_summary).to include('receipt_status' => 'completed')
      end
    end

    it 'AI TimeoutはOCR fallbackでreview_neededにし、receipt全体をfailedにしない' do
      expect_ai_fallback_contract('ai_timeout')
    end

    it 'AI API ErrorはOCR fallbackでreview_neededにし、receipt全体をfailedにしない' do
      expect_ai_fallback_contract('ai_api_error')
    end

    it 'AI Invalid ResponseはOCR fallbackでreview_neededにし、receipt全体をfailedにしない' do
      receipt, run = build_processing_run
      record_ocr_snapshot(run)
      stub_services_available
      stub_amount_service
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return('invalid ai response')

      ai_stage = ReceiptAnalysisPipeline.run_ai(run)
      finalize_stage = ReceiptAnalysisPipeline.run_finalize(run)
      receipt.reload
      run.reload

      aggregate_failures do
        expect(ai_stage.finalize_decision.finalize_strategy).to eq('ai_fallback')
        expect(ai_stage.finalize_decision.error_code).to eq('ai_invalid_response')
        expect(finalize_stage.next_step).to eq(:done)
        expect(receipt.status).to eq('review_needed')
        expect(receipt.processing_error_code).to eq('ai_invalid_response')
        expect(receipt.review_reasons).to eq([])
        expect(receipt.receipt_items.sole.raw_text).to eq('コーヒー')
        expect(receipt.receipt_items.sole.confirmed_name).to be_nil
        expect(run.final_result_summary).to include('receipt_status' => 'review_needed')
      end
    end

    it 'AI Provider Errorはsafe messageだけを残してreview_neededにし、receipt全体をfailedにしない' do
      ai_result = failed_ai_result(
        'ai_primary_failed',
        meta: {
          primary_provider: 'openai',
          primary_error_code: 'ai_primary_failed',
          primary_error_message: 'Net::ReadTimeout with prompt=secret sk-test'
        }
      )
      expected_message = 'AI補完に失敗したためOCR結果で保存しました (provider=openai, code=ai_primary_failed, reason=timeout)'

      expect_ai_fallback_contract(
        'ai_primary_failed',
        ai_result: ai_result,
        processing_error_message: expected_message
      )
    end
  end

  describe 'Amount Engine persistence/status contract' do
    it 'needs_reviewのamount resultはreview_neededにし、Receipt.total_amountにはpurchase totalを保存する' do
      amount_result = no_amount_mismatch_result.deep_merge(
        resolved: {
          total: 1_000,
          subtotal: 909,
          tax: 91,
          tax_rate: BigDecimal('0.10')
        },
        computed: {
          items: [],
          purchase_total: 1_000,
          final_payment_total: 900,
          payment_adjustment_total: -100,
          payment_amount_sum: 900
        },
        blocking_inconsistencies: [ :payment_amount_mismatch ],
        warning_inconsistencies: [],
        review_reasons: [ 'payment_amount_mismatch' ],
        needs_review: true
      )

      receipt, run, _ai_stage, finalize_stage = run_ai_and_finalize(successful_ai_result, amount_result: amount_result)

      aggregate_failures do
        expect(finalize_stage.next_step).to eq(:done)
        expect(receipt.status).to eq('review_needed')
        expect(receipt.total_amount).to eq(1_000)
        expect(receipt.subtotal_amount).to eq(909)
        expect(receipt.tax_amount).to eq(91)
        expect(receipt.amount_calculation_profile.dig('resolved', 'total_amount')).to eq(1_000)
        expect(receipt.amount_calculation_profile.dig('computed', 'final_payment_total')).to eq(900)
        expect(receipt.amount_calculation_profile.dig('computed', 'payment_adjustment_total')).to eq(-100)
        expect(receipt.review_reasons).to include('payment_amount_mismatch')
        expect(run.final_result_summary).to include('receipt_status' => 'review_needed')
      end
    end
  end

  describe 'OCR status contract' do
    it 'OCR成功かつAI有効ならAI stepへ進め、receiptはprocessingのままにする' do
      receipt, run = build_processing_run
      stub_services_available
      allow(ReceiptOcrService).to receive(:call).and_return(successful_ocr_result)

      result = ReceiptAnalysisPipeline.run_ocr(run)

      aggregate_failures do
        expect(result.next_step).to eq(:ai)
        expect(result.finalize_decision).to be_nil
        expect(receipt.reload.status).to eq('processing')
        expect(receipt.processing_error_code).to be_nil
        expect(run.reload.metadata['finalize_decision']).to be_blank
      end
    end

    it 'OCR Provider Errorはfailedにする' do
      expect_ocr_failure_contract('external_service_unavailable')
    end

    it 'OCR Timeoutはfailedにする' do
      expect_ocr_failure_contract('ocr_timeout')
    end

    it 'OCR画像不正はfailedにする' do
      expect_ocr_failure_contract('image_corrupted')
    end

    it '非レシート画像はfailedにする' do
      non_receipt_ocr = successful_ocr_result(
        raw_text: 'これは買い物メモです',
        lines: [ 'これは買い物メモです' ],
        candidates: {
          store_name: nil,
          total_amount: nil,
          payment_method_text: nil,
          country_region: nil,
          items: [],
          payments: [],
          tax_details: []
        }
      )

      expect_ocr_failure_contract('receipt_not_detected', ocr_result: non_receipt_ocr)
    end

    it 'OCRレスポンス異常はocr_api_errorとしてfailedにする' do
      expect_ocr_failure_contract('ocr_api_error')
    end
  end
end
