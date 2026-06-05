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
        purchased_at: Time.zone.parse('2026-05-23 10:00:00'),
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

  def rich_ocr_result(overrides = {})
    {
      success: true,
      raw_text: "サンプルストア\n2026/04/02 12:34\nコーヒー 180\nサンド 550 x2\n合計 1280\nMaster",
      lines: [
        'サンプルストア',
        '2026/04/02 12:34',
        'コーヒー 180',
        'サンド 550 x2',
        '合計 1280',
        'Master'
      ],
      candidates: {
        store_name: 'サンプルストア',
        purchased_at_text: '2026/04/02 12:34',
        total_amount: 1280,
        tip_amount: 100,
        country_region: 'JPN',
        receipt_type: 'Meal',
        payment_method_text: 'Master',
        items: [
          {
            raw_text: 'コーヒー',
            price: 180,
            quantity: 1,
            quantity_unit: '杯',
            product_code: 'C001',
            line_total: 180,
            tax_rate: 10,
            confidence: 0.98
          },
          {
            raw_text: 'サンド',
            price: 550,
            quantity: 2,
            quantity_unit: '個',
            product_code: 'S001',
            line_total: 1100,
            tax_rate: 10,
            confidence: 0.97
          }
        ],
        payments: [
          { method: 'CreditCard', amount: 1280 }
        ],
        tax_details: [
          { description: 'Sales Tax', amount: 116, rate: 10, net_amount: 1164 }
        ]
      },
      error_code: nil,
      meta: {
        provider: 'azure_document_intelligence',
        model_id: 'prebuilt-receipt',
        confidence_summary: {
          items_average: 0.95,
          overall: 0.95
        }
      }
    }.deep_merge(overrides)
  end

  def weak_receipt_like_ocr_result
    rich_ocr_result(
      raw_text: "サンプルストア\n2026/04/02 12:34\nTEL 03-1234-5678\n東京都港区芝1-1-1\nコーヒー\nサンド\nケーキ",
      lines: [
        'サンプルストア',
        '2026/04/02 12:34',
        'TEL 03-1234-5678',
        '東京都港区芝1-1-1',
        'コーヒー',
        'サンド',
        'ケーキ'
      ],
      candidates: {
        store_name: 'サンプルストア',
        store_address: '東京都港区芝1-1-1',
        store_phone_number: '03-1234-5678',
        purchased_at_text: '2026/04/02 12:34',
        total_amount: nil,
        tip_amount: nil,
        country_region: 'JPN',
        receipt_type: nil,
        payment_method_text: nil,
        items: [
          { raw_text: 'コーヒー', line_total: 180, confidence: 0.95 },
          { raw_text: 'サンド', line_total: 550, confidence: 0.95 },
          { raw_text: 'ケーキ', line_total: 320, confidence: 0.95 }
        ],
        payments: [],
        tax_details: []
      }
    )
  end

  def failed_ai_result(error_code = 'analysis_missing_keys')
    {
      success: false,
      error_code: error_code,
      receipt_attributes: {},
      receipt_items_attributes: []
    }
  end

  def timeout_ai_result
    {
      success: false,
      error_code: 'ai_primary_failed',
      receipt_attributes: {},
      receipt_items_attributes: [],
      meta: {
        primary_provider: 'openai',
        fallback_used: false,
        primary_error_code: 'ai_primary_failed',
        primary_error_message: 'Net::ReadTimeout with prompt=secret sk-test'
      }
    }
  end

  def ai_success_result_for(ocr_result, review_reasons: [], needs_review: false)
    {
      success: true,
      needs_review: needs_review,
      review_reasons: review_reasons,
      receipt_attributes: {
        payment_method: 'cash'
      },
      receipt_items_attributes: Array(ocr_result.dig(:candidates, :items)).each_with_index.map do |_item, index|
        {
          index: index,
          category: 'other',
          needs_review: false
        }
      end
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

  def ocr_fixture(name)
    raw_json = JSON.parse(Rails.root.join("spec/fixtures/ocr/#{name}.json").read)

    Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call
  end

  def run_finalize_ocr_fixture(name, ai_result: nil)
    receipt = create(:receipt, :processing, :with_image)
    ocr_result = ocr_fixture(name)
    ai_result ||= ai_success_result_for(ocr_result)
    captured_amount_result = nil

    allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **kwargs|
      captured_amount_result = original.call(**kwargs)
    end

    described_class.finalize(
      receipt: receipt,
      decision: finalize_decision(
        :ai_success,
        ocr_result: ocr_result,
        ai_result: ai_result
      )
    )

    [ receipt.reload, captured_amount_result ]
  end

  def with_env(key, value)
    original_value = ENV[key]
    ENV[key] = value
    yield
  ensure
    if original_value.nil?
      ENV.delete(key)
    else
      ENV[key] = original_value
    end
  end

  def ai_not_receipt_result(confidence: 0.92)
    {
      success: false,
      error_code: 'ai_not_receipt',
      needs_review: false,
      receipt_attributes: {},
      receipt_items_attributes: [],
      meta: {
        document_type: 'development_note',
        rejection_reason: 'memo',
        is_receipt_confidence: confidence
      }
    }
  end

  describe '.run_ocr' do
    it 'OCR成功かつAI有効ならAI stepへ進める' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)

      allow(ReceiptOcrService).to receive(:call).and_return(successful_ocr_result)
      allow(ExternalServices).to receive(:down?).with(:ai).and_return(false)

      result = described_class.run_ocr(run)

      aggregate_failures do
        expect(result.next_step).to eq(:ai)
        expect(result.ocr_result).to eq(successful_ocr_result)
        expect(result.finalize_decision).to be_nil
        expect(run.reload.stage).to eq('ocr_validation')
        expect(run.metadata['finalize_decision']).to be_blank
      end
    end

    it 'OCR失敗ならfinalize decisionを保存してFinalizeへ進める' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      ocr_result = {
        success: false,
        error_code: 'ocr_timeout',
        lines: [],
        candidates: {},
        meta: {
          provider: 'azure_document_intelligence',
          polling_metrics: {
            poll_count: 20,
            final_status: 'running',
            reached_max_poll: true,
            retry_count: 0
          }
        }
      }

      allow(ReceiptOcrService).to receive(:call).and_return(ocr_result)

      result = described_class.run_ocr(run)

      aggregate_failures do
        expect(result.next_step).to eq(:finalize)
        expect(result.finalize_decision.finalize_strategy).to eq('fail_receipt')
        expect(result.finalize_decision.error_code).to eq('ocr_timeout')
        expect(run.reload.metadata.dig('finalize_decision', 'strategy')).to eq('fail_receipt')
        expect(run.metadata.dig('finalize_decision', 'error_code')).to eq('ocr_timeout')
        expect(run.ocr_summary.dig('polling_metrics', 'poll_count')).to eq(20)
        expect(run.ocr_result_snapshot.dig('meta', 'polling_metrics', 'reached_max_poll')).to eq(true)
      end
    end

    it 'OCR validation失敗なら理由別のfinalize decisionを保存する' do
      cases = {
        unsupported_country: [
          successful_ocr_result.deep_merge(candidates: { country_region: 'USA' }),
          'unsupported_country'
        ],
        no_text_detected: [
          successful_ocr_result.deep_merge(
            raw_text: '',
            lines: [],
            candidates: {
              store_name: nil,
              total_amount: nil,
              payment_method_text: nil,
              country_region: nil,
              items: [],
              payments: [],
              tax_details: []
            }
          ),
          'no_text_detected'
        ],
        ocr_unreadable: [
          successful_ocr_result.deep_merge(candidates: { confidence_summary: { overall: 0.2 } }),
          'ocr_unreadable'
        ],
        receipt_not_detected: [
          successful_ocr_result.deep_merge(
            raw_text: 'これはメモです',
            lines: [ 'これはメモです' ],
            candidates: {
              store_name: nil,
              total_amount: nil,
              payment_method_text: nil,
              country_region: nil,
              items: [],
              payments: [],
              tax_details: []
            }
          ),
          'receipt_not_detected'
        ]
      }

      cases.each do |label, (ocr_result, error_code)|
        receipt = create(:receipt, :processing, :with_image)
        run = create(:receipt_analysis_run, receipt:)

        allow(ReceiptOcrService).to receive(:call).and_return(ocr_result)

        result = described_class.run_ocr(run)

        aggregate_failures(label) do
          expect(result.next_step).to eq(:finalize)
          expect(result.finalize_decision.finalize_strategy).to eq('fail_receipt')
          expect(result.finalize_decision.error_code).to eq(error_code)
          expect(run.reload.metadata.dig('finalize_decision', 'error_code')).to eq(error_code)
        end
      end
    end

    it 'AI disabled/downならfinalize decisionを保存してFinalizeへ進める' do
      ai_disabled_receipt = create(:receipt, :processing, :with_image)
      ai_disabled_run = create(:receipt_analysis_run, receipt: ai_disabled_receipt)
      ai_down_receipt = create(:receipt, :processing, :with_image)
      ai_down_run = create(:receipt_analysis_run, receipt: ai_down_receipt)

      allow(ReceiptOcrService).to receive(:call).and_return(successful_ocr_result)

      with_env('RECEIPT_AI_ENABLED', 'false') do
        disabled_result = described_class.run_ocr(ai_disabled_run)

        aggregate_failures('disabled') do
          expect(disabled_result.next_step).to eq(:finalize)
          expect(disabled_result.finalize_decision.finalize_strategy).to eq('ocr_only')
          expect(ai_disabled_run.reload.metadata.dig('finalize_decision', 'strategy')).to eq('ocr_only')
        end
      end

      allow(ExternalServices).to receive(:down?).with(:ai).and_return(true)
      down_result = described_class.run_ocr(ai_down_run)

      aggregate_failures('down') do
        expect(down_result.next_step).to eq(:finalize)
        expect(down_result.finalize_decision.finalize_strategy).to eq('ai_fallback')
        expect(down_result.finalize_decision.error_code).to eq('ai_unavailable')
        expect(ai_down_run.reload.metadata.dig('finalize_decision', 'error_code')).to eq('ai_unavailable')
      end
    end

    it 'OCR disabledならocr_disabled decisionを保存してFinalizeへ進める' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      expect(ReceiptOcrService).not_to receive(:call)

      with_env('RECEIPT_OCR_ENABLED', 'false') do
        result = described_class.run_ocr(run)

        aggregate_failures do
          expect(result.next_step).to eq(:finalize)
          expect(result.finalize_decision.finalize_strategy).to eq('fail_receipt')
          expect(result.finalize_decision.error_code).to eq('ocr_disabled')
          expect(run.reload.metadata.dig('finalize_decision', 'error_code')).to eq('ocr_disabled')
          expect(run.ocr_result_snapshot).to include(
            'success' => false,
            'error_code' => 'ocr_disabled'
          )
        end
      end
    end

    it 'OCR stepの予期しない例外ではrunとprocessing receiptをfailedにする' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)

      allow(ReceiptOcrService).to receive(:call).and_raise(StandardError, 'OCR raw token=secret')

      expect { described_class.run_ocr(run) }.to raise_error(StandardError, 'OCR raw token=secret')

      aggregate_failures do
        expect(run.reload.status).to eq('failed')
        expect(run.error_stage).to eq('ocr')
        expect(run.error_code).to eq('unexpected_error')
        expect(receipt.reload.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('unexpected_error')
        expect(receipt.processing_error_message).to eq('解析処理中にエラーが発生しました。再試行してください。')
        expect(receipt.processing_error_message).not_to include('token', 'secret', 'OCR raw')
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
        expect(result.ai_result).to include(
          success: true,
          error_code: nil,
          needs_review: false,
          review_reasons: [],
          receipt_attributes: { payment_method: 'cash' }
        )
        expect(result.finalize_decision.finalize_strategy).to eq('ai_success')
        expect(result.next_step).to eq(:finalize)
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

    it 'OCR snapshotからAIを実行してfinalize decisionを保存する' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)

      ReceiptAnalysisRuns.record_ocr_snapshot(run, successful_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(successful_ai_result)

      result = described_class.run_ai(run)

      aggregate_failures do
        expect(ReceiptAiEnrichmentService).to have_received(:call).once
        expect(result.next_step).to eq(:finalize)
        expect(result.finalize_decision.finalize_strategy).to eq('ai_success')
        expect(run.reload.metadata.dig('finalize_decision', 'strategy')).to eq('ai_success')
      end
    end

    it 'AI stepの予期しない例外ではrunとprocessing receiptをfailedにする' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)

      ReceiptAnalysisRuns.record_ocr_snapshot(run, successful_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_raise(StandardError, 'AI prompt sk-test')

      expect { described_class.run_ai(run) }.to raise_error(StandardError, 'AI prompt sk-test')

      aggregate_failures do
        expect(run.reload.status).to eq('failed')
        expect(run.error_stage).to eq('ai')
        expect(run.error_code).to eq('unexpected_error')
        expect(receipt.reload.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('unexpected_error')
        expect(receipt.processing_error_message).to eq('解析処理中にエラーが発生しました。再試行してください。')
        expect(receipt.processing_error_message).not_to include('prompt', 'sk-test')
      end
    end

    it 'AI failure / not_receiptでfinalize decisionを保存する' do
      failure_receipt = create(:receipt, :processing, :with_image)
      failure_run = create(:receipt_analysis_run, receipt: failure_receipt)
      not_receipt_receipt = create(:receipt, :processing, :with_image)
      not_receipt_run = create(:receipt_analysis_run, receipt: not_receipt_receipt)
      weak_ocr_result = successful_ocr_result.deep_merge(
        raw_text: "メモ\n電話番号 03-1234-5678",
        lines: [ 'メモ', '電話番号 03-1234-5678' ],
        candidates: {
          total_amount: nil,
          payment_method_text: nil,
          tax_details: [],
          payments: [],
          items: [
            { raw_text: 'メモ', confidence: 0.95 }
          ]
        }
      )

      ReceiptAnalysisRuns.record_ocr_snapshot(failure_run, successful_ocr_result)
      ReceiptAnalysisRuns.record_ocr_snapshot(not_receipt_run, weak_ocr_result)

      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(
        { success: false, error_code: 'analysis_missing_keys', receipt_attributes: {}, receipt_items_attributes: [] },
        ai_not_receipt_result(confidence: 0.92)
      )

      failure_result = described_class.run_ai(failure_run)
      not_receipt_result = described_class.run_ai(not_receipt_run)

      aggregate_failures do
        expect(failure_result.finalize_decision.finalize_strategy).to eq('ai_fallback')
        expect(failure_result.finalize_decision.error_code).to eq('analysis_missing_keys')
        expect(failure_run.reload.metadata.dig('finalize_decision', 'error_code')).to eq('analysis_missing_keys')
        expect(not_receipt_result.finalize_decision.finalize_strategy).to eq('fail_receipt')
        expect(not_receipt_result.finalize_decision.error_code).to eq('ai_not_receipt')
        expect(not_receipt_run.reload.metadata.dig('finalize_decision', 'error_code')).to eq('ai_not_receipt')
      end
    end

    it 'AI not receiptのconfidenceとOCR証拠でfinalize strategyを分岐する' do
      cases = [
        [ 'high confidence with strong OCR evidence', successful_ocr_result, 0.92, 'ai_fallback', 'ai_not_receipt_uncertain' ],
        [ 'medium confidence with strong OCR evidence', successful_ocr_result, 0.65, 'ai_fallback', 'ai_not_receipt_uncertain' ],
        [ 'medium confidence without strong OCR evidence', weak_receipt_like_ocr_result, 0.65, 'fail_receipt', 'ai_not_receipt' ],
        [ 'missing confidence', weak_receipt_like_ocr_result, nil, 'ai_fallback', 'ai_not_receipt_uncertain' ],
        [ 'low confidence', weak_receipt_like_ocr_result, 0.3, 'ai_fallback', 'ai_not_receipt_uncertain' ]
      ]

      cases.each do |label, ocr_result, confidence, expected_strategy, expected_error_code|
        receipt = create(:receipt, :processing, :with_image)
        run = create(:receipt_analysis_run, receipt:)

        allow(ReceiptAiEnrichmentService).to receive(:call).and_return(
          ai_not_receipt_result(confidence: confidence)
        )

        result = described_class.run_ai(run: run, ocr_result: ocr_result)

        aggregate_failures(label) do
          expect(result.finalize_decision.finalize_strategy).to eq(expected_strategy)
          expect(result.finalize_decision.error_code).to eq(expected_error_code)
          expect(run.reload.metadata.dig('finalize_decision', 'strategy')).to eq(expected_strategy)
          expect(run.metadata.dig('finalize_decision', 'error_code')).to eq(expected_error_code)
        end
      end
    end

    it 'AI fallback messageはprovider raw errorやprompt/secretを露出しない' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)

      ReceiptAnalysisRuns.record_ocr_snapshot(run, rich_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(timeout_ai_result)

      result = described_class.run_ai(run)

      aggregate_failures do
        expect(result.finalize_decision.finalize_strategy).to eq('ai_fallback')
        expect(result.finalize_decision.error_code).to eq('ai_primary_failed')
        expect(result.finalize_decision.error_message).to eq(
          'AI補完に失敗したためOCR結果で保存しました (provider=openai, code=ai_primary_failed, reason=timeout)'
        )
        expect(result.finalize_decision.error_message).not_to include('Net::ReadTimeout', 'prompt', 'sk-test')
      end

      described_class.run_finalize(run)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.processing_error_code).to eq('ai_primary_failed')
        expect(receipt.processing_error_message).not_to include('Net::ReadTimeout', 'prompt', 'sk-test')
      end
    end

    it 'AI responseが非Hashならai_invalid_responseとしてFinalizeできる' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)

      ReceiptAnalysisRuns.record_ocr_snapshot(run, rich_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return('invalid ai response')

      result = described_class.run_ai(run)

      aggregate_failures do
        expect(result.finalize_decision.finalize_strategy).to eq('ai_fallback')
        expect(result.finalize_decision.error_code).to eq('ai_invalid_response')
      end

      described_class.run_finalize(run)

      aggregate_failures do
        expect(receipt.reload.status).to eq('review_needed')
        expect(receipt.processing_error_code).to eq('ai_invalid_response')
      end
    end
  end

  describe '.finalize_decision_from_snapshot' do
    it '保存済みsnapshotからdecisionを復元しocr/ai resultは復元しない' do
      snapshot = {
        schema_version: 'receipt_analysis_run_finalize_decision_v1',
        strategy: 'fail_receipt',
        error_code: 'unsupported_country',
        error_message: 'country_region=USA',
        receipt_attributes: { country_region: 'USA' },
        metadata: { reason: 'unsupported_country' },
        ocr_result: { raw_text: '保存しないOCR全文' },
        ai_result: { messages: [ '保存しないmessages' ] }
      }

      decision = described_class.finalize_decision_from_snapshot(snapshot)

      aggregate_failures do
        expect(decision.finalize_strategy).to eq('fail_receipt')
        expect(decision.error_code).to eq('unsupported_country')
        expect(decision.error_message).to eq('country_region=USA')
        expect(decision.receipt_attributes).to eq('country_region' => 'USA')
        expect(decision.metadata).to eq('reason' => 'unsupported_country')
        expect(decision.ocr_result).to be_nil
        expect(decision.ai_result).to be_nil
      end
    end

    it '空または不正なsnapshotはnilを返す' do
      aggregate_failures do
        expect(described_class.finalize_decision_from_snapshot(nil)).to be_nil
        expect(
          described_class.finalize_decision_from_snapshot(
            schema_version: 'old',
            strategy: 'ai_success'
          )
        ).to be_nil
        expect(
          described_class.finalize_decision_from_snapshot(
            schema_version: 'receipt_analysis_run_finalize_decision_v1',
            strategy: 'unknown'
          )
        ).to be_nil
      end
    end
  end

  describe '.run_finalize' do
    it 'metadata decisionとsnapshotだけで保存しrunをsucceededにする' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      decision = finalize_decision(:ai_success)

      ReceiptAnalysisRuns.record_ocr_snapshot(run, successful_ocr_result)
      ReceiptAnalysisRuns.record_ai_normalized_result(run, successful_ai_result)
      ReceiptAnalysisRuns.record_finalize_decision(run, decision)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [],
          blocking_inconsistencies: [],
          warning_inconsistencies: []
        )
      )

      result = described_class.run_finalize(run)

      aggregate_failures do
        expect(result.next_step).to eq(:done)
        expect(receipt.reload.status).to eq('completed')
        expect(run.reload.status).to eq('succeeded')
        expect(run.stage).to eq('completed')
        expect(run.final_result_summary).to include(
          'receipt_status' => 'completed',
          'item_count' => 1
        )
      end
    end

    it 'BuildParams snapshotに購入時刻fallbackのsafe metadataを保存する' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      decision = finalize_decision(:ai_success)
      ocr_result = successful_ocr_result.deep_merge(
        lines: [
          '2026年 4月19日(日)No2',
          '駐車券自家用車等',
          '0796 16時41分'
        ],
        candidates: {
          purchased_at_text: '2026-04-19',
          purchased_at_candidates: [ '0796 16時41分' ],
          purchase_context_lines: [ '領収書', '0796 16時41分' ]
        }
      )
      ai_result = successful_ai_result.merge(
        receipt_attributes: {
          store_name: 'AIテストストア',
          purchased_at_text: '2026-04-19',
          payment_method: 'cash'
        }
      )

      ReceiptAnalysisRuns.record_ocr_snapshot(run, ocr_result)
      ReceiptAnalysisRuns.record_ai_normalized_result(run, ai_result)
      ReceiptAnalysisRuns.record_finalize_decision(run, decision)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [],
          blocking_inconsistencies: [],
          warning_inconsistencies: []
        )
      )

      described_class.run_finalize(run)

      snapshot = run.reload.metadata.fetch('build_params_snapshot')
      snapshot_json = JSON.generate(snapshot)

      aggregate_failures do
        expect(snapshot).to include('schema_version' => 'receipt_analysis_run_build_params_v1')
        expect(snapshot.dig('receipt_attributes', 'purchased_at')).to eq('2026-04-19T16:41:00+09:00')
        expect(snapshot.dig('corrections', 'purchased_at_fallback')).to include(
          'applied' => true,
          'source' => 'ocr_time_candidate',
          'date_text' => '2026-04-19',
          'time_text' => '16時41分',
          'ignored_prefix' => '0796',
          'result' => '2026-04-19 16:41'
        )
        expect(snapshot).to include(
          'receipt_items_count' => 1,
          'receipt_adjustments_count' => 0,
          'receipt_tax_details_count' => 0
        )
        expect(snapshot_json).not_to include('blob_key', 'signed_id', 'api_key', 'token', 'secret', 'prompt', 'raw_response')
      end
    end

    it 'finalize decisionが欠落している場合はrunをfailedにする' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)

      result = described_class.run_finalize(run)

      aggregate_failures do
        expect(result.next_step).to eq(:skipped)
        expect(result.skip_reason).to eq(:finalize_decision_missing)
        expect(run.reload.status).to eq('failed')
        expect(run.error_stage).to eq('finalize')
        expect(run.error_code).to eq('finalize_decision_missing')
        expect(receipt.reload.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('finalize_decision_missing')
        expect(receipt.processing_error_message).to eq('解析処理中にエラーが発生しました。再試行してください。')
      end
    end

    it '明細数がuser limitを超える解析結果は金額計算前にrunをfailedにする' do
      user = create(:user)
      create(:user_limit_override, user: user, key: 'receipt_items_per_receipt', value: { 'value' => 1 })
      receipt = create(:receipt, :processing, :with_image, user: user)
      run = create(:receipt_analysis_run, receipt:)
      decision = finalize_decision(:ocr_only)
      ocr_result = successful_ocr_result.deep_dup
      ocr_result[:candidates][:items] = [
        { raw_text: '商品A', price: 100, quantity: 1, line_total: 100 },
        { raw_text: '商品B', price: 100, quantity: 1, line_total: 100 }
      ]

      ReceiptAnalysisRuns.record_ocr_snapshot(run, ocr_result)
      ReceiptAnalysisRuns.record_finalize_decision(run, decision)
      expect(ReceiptAmountService).not_to receive(:call)

      expect {
        described_class.run_finalize(run)
      }.to raise_error(ReceiptAnalysisPipeline::AnalysisError, /receipt_items_limit_exceeded/)

      aggregate_failures do
        expect(run.reload.status).to eq('failed')
        expect(run.error_stage).to eq('finalize')
        expect(run.error_code).to eq('analysis_items_invalid')
        expect(receipt.reload.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('analysis_items_invalid')
        expect(receipt.receipt_items).to be_empty
      end
    end

    it 'finalize中に計算結果へ負値item金額が混じっても通常明細へ保存しない' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      decision = finalize_decision(:ai_success)

      ReceiptAnalysisRuns.record_ocr_snapshot(run, successful_ocr_result)
      ReceiptAnalysisRuns.record_ai_normalized_result(run, successful_ai_result)
      ReceiptAnalysisRuns.record_finalize_decision(run, decision)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [],
          blocking_inconsistencies: [],
          warning_inconsistencies: []
        ).deep_merge(
          computed: {
            items: [
              {
                price: -2160,
                quantity: 1,
                line_total: -2160
              }
            ]
          }
        )
      )

      expect { described_class.run_finalize(run) }.not_to raise_error

      aggregate_failures do
        expect(run.reload.status).to eq('succeeded')
        expect(receipt.reload.status).to eq('completed')
        expect(receipt.receipt_items).not_to be_empty
        expect(receipt.receipt_items).to all(have_attributes(price: be >= 0, line_total: be >= 0))
      end
    end

    it 'すでにcompletedのreceiptはrun失敗同期で上書きしない' do
      receipt = create(:receipt, :completed, :with_image)
      run = create(:receipt_analysis_run, receipt:)

      ReceiptAnalysisRuns.fail(
        run,
        error_stage: 'finalize',
        error_code: 'unexpected_error',
        error_message: 'stacktrace token=secret'
      )

      aggregate_failures do
        expect(run.reload.status).to eq('failed')
        expect(receipt.reload.status).to eq('completed')
        expect(receipt.processing_error_code).to be_nil
        expect(receipt.processing_error_message).to be_nil
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

    it '画像保持OFFのai_success完了後にpurge候補化する' do
      receipt = create(:receipt, :processing, :with_image, keep_image: false)
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
          :ai_success,
          ocr_result: successful_ocr_result,
          ai_result: successful_ai_result
        )
      )

      aggregate_failures do
        expect(receipt.reload.status).to eq('completed')
        expect(receipt.image_purge_eligible_at).to be_present
        expect(receipt.image_purged_at).to be_nil
        expect(receipt.image_purged_reason).to be_nil
      end
    end

    it 'AIの特殊加減算をreceipt_adjustmentsとして保存し金額へ反映する' do
      receipt = create(:receipt, :processing, :with_image)
      ocr_result = {
        success: true,
        raw_text: "テストストア\n商品 180\n配送料\n¥550\nレジ袋代\n¥10\n合計 740\n現金",
        lines: [
          'テストストア',
          '商品 180',
          '配送料',
          '¥550',
          'レジ袋代',
          '¥10',
          '合計 740',
          '現金'
        ],
        candidates: {
          store_name: 'テストストア',
          total_amount: 740,
          country_region: 'JPN',
          payment_method_text: '現金',
          items: [
            {
              raw_text: '商品',
              price: 180,
              quantity: 1,
              line_total: 180,
              confidence: 0.95
            }
          ],
          payments: [
            { method: 'Cash', amount: 740 }
          ],
          tax_details: []
        }
      }
      ai_result = successful_ai_result.merge(
        receipt_attributes: {
          store_name: 'テストストア',
          payment_method: 'cash'
        },
        receipt_items_attributes: [
          { index: 0, suggested_name: '商品', category: 'other', needs_review: false, confidence: 0.95 }
        ],
        receipt_adjustments_attributes: [
          {
            kind: 'delivery_fee',
            label: '配送料',
            amount: 550,
            sign: 'surcharge',
            source_text: '配送料',
            source_line_index: 2,
            confidence: BigDecimal('0.9')
          },
          {
            kind: 'bag_fee',
            label: 'レジ袋代',
            amount: 10,
            sign: 'surcharge',
            source_text: 'レジ袋代',
            source_line_index: 4,
            confidence: BigDecimal('0.9')
          }
        ]
      )

      described_class.finalize(
        receipt: receipt,
        decision: finalize_decision(
          :ai_success,
          ocr_result: ocr_result,
          ai_result: ai_result
        )
      )

      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.total_amount).to eq(740)
        expect(receipt.receipt_adjustments.pluck(:kind, :amount, :sign)).to contain_exactly(
          [ 'delivery_fee', 550, 'surcharge' ],
          [ 'bag_fee', 10, 'surcharge' ]
        )
      end
    end

    it 'return_receiptの返品行をadjustmentとして保存しfinalize失敗にしない' do
      ocr_result = ocr_fixture('return_receipt')
      ai_result = ai_success_result_for(ocr_result).merge(
        receipt_adjustments_attributes: [
          {
            kind: 'return_refund',
            label: '返品(液体洗剤)',
            amount: 980,
            sign: 'discount',
            source_text: '返品(液体洗剤)',
            source_line_index: 12,
            confidence: BigDecimal('0.9')
          }
        ]
      )

      receipt, = run_finalize_ocr_fixture('return_receipt', ai_result: ai_result)

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.store_name).to eq('ライフスマイルマーケット 渋谷店')
        expect(receipt.receipt_adjustments.pluck(:kind, :amount, :sign)).to include([ 'return_refund', 980, 'discount' ])
      end
    end

    it 'delivery_and_bag_fee_receiptの配送料と袋代をadjustmentとして保存する' do
      ocr_result = ocr_fixture('delivery_and_bag_fee_receipt')
      ai_result = ai_success_result_for(ocr_result).merge(
        receipt_adjustments_attributes: [
          {
            kind: 'bag_fee',
            label: 'レジ袋代',
            amount: 10,
            sign: 'surcharge',
            source_text: 'レジ袋代',
            source_line_index: 17,
            confidence: BigDecimal('0.9')
          },
          {
            kind: 'delivery_fee',
            label: '配送料',
            amount: 550,
            sign: 'surcharge',
            source_text: '配送料',
            source_line_index: 19,
            confidence: BigDecimal('0.9')
          }
        ]
      )

      receipt, amount = run_finalize_ocr_fixture('delivery_and_bag_fee_receipt', ai_result: ai_result)

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.store_name).to eq('スマイルデリバリー 東京中央店')
        expect(receipt.receipt_adjustments.pluck(:kind, :amount, :sign)).to contain_exactly(
          [ 'bag_fee', 10, 'surcharge' ],
          [ 'delivery_fee', 550, 'surcharge' ]
        )
        expect(amount.dig(:computed, :tax_detail_amount_basis)).not_to eq(:gross)
      end
    end

    it 'service_and_late_night_receiptのサービス料と深夜料金をadjustmentとして保存する' do
      ocr_result = ocr_fixture('service_and_late_night_receipt')
      ai_result = ai_success_result_for(ocr_result).merge(
        receipt_adjustments_attributes: [
          {
            kind: 'service_charge',
            label: 'サービス料10%',
            amount: 486,
            sign: 'surcharge',
            source_text: 'サービス料10%',
            source_line_index: 14,
            confidence: BigDecimal('0.9')
          },
          {
            kind: 'late_night_charge',
            label: '深夜料金10%',
            amount: 486,
            sign: 'surcharge',
            source_text: '深夜料金10%',
            source_line_index: 16,
            confidence: BigDecimal('0.9')
          }
        ]
      )

      receipt, amount = run_finalize_ocr_fixture('service_and_late_night_receipt', ai_result: ai_result)

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.store_name).to eq('ナイトダイニング 月灯り 新宿店')
        expect(receipt.receipt_adjustments.pluck(:kind, :amount, :sign)).to contain_exactly(
          [ 'service_charge', 486, 'surcharge' ],
          [ 'late_night_charge', 486, 'surcharge' ]
        )
        expect(amount.dig(:computed, :tax_detail_amount_basis)).not_to eq(:gross)
      end
    end

    it 'ai_success decisionのwarning mismatchはcompletedのままreview_reasonsに残さず診断情報に残す' do
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
        expect(receipt.review_reasons).to be_blank
        expect(receipt.amount_calculation_profile).to include(
          'warnings' => [ 'price_tax_inclusion_uncertain' ],
          'warning_mismatch_codes' => [ 'PRICE_TAX_INCLUSION_UNCERTAIN' ],
          'blocking_mismatch_codes' => []
        )
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

    it '画像保持OFFのocr_only完了後にpurge候補化する' do
      receipt = create(:receipt, :processing, :with_image, keep_image: false)
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
        expect(receipt.image_purge_eligible_at).to be_present
        expect(receipt.image_purged_at).to be_nil
        expect(receipt.image_purged_reason).to be_nil
      end
    end

    it 'ocr_only decisionでも高信頼OCR adjustment candidateを保存しreview_neededにする' do
      receipt = create(:receipt, :processing, :with_image)
      ocr_result = ocr_fixture('service_and_late_night_receipt')

      described_class.finalize(
        receipt: receipt,
        decision: finalize_decision(:ocr_only, ocr_result: ocr_result)
      )
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.processing_error_code).to be_nil
        expect(receipt.receipt_adjustments.pluck(:kind, :amount, :sign, :source)).to contain_exactly(
          [ 'service_charge', 486, 'surcharge', 'ocr' ],
          [ 'late_night_charge', 486, 'surcharge', 'ocr' ]
        )
        expect(receipt.review_reasons).to include('adjustment_uncertain')
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

    it '画像保持OFFのai_fallback完了後にpurge候補化する' do
      receipt = create(:receipt, :processing, :with_image, keep_image: false)
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
          error_code: 'ai_unavailable'
        )
      )

      expect(receipt.reload.image_purge_eligible_at).to be_present
    end

    it 'ai_fallback decisionはmapper経由でnil error_codeをunexpected_errorとして保存する' do
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
          error_code: nil
        )
      )

      aggregate_failures do
        expect(receipt.reload.status).to eq('review_needed')
        expect(receipt.processing_error_code).to eq('unexpected_error')
        expect(receipt.review_reasons).to be_blank
      end
    end

    it 'AI成功ルートではlow_quality_ocr?を1回だけ評価する' do
      receipt = create(:receipt, :processing, :with_image)
      expect_any_instance_of(ReceiptAnalysisPipeline::FinalizeStep)
        .to receive(:low_quality_ocr?)
        .once
        .and_call_original
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
          :ai_success,
          ocr_result: successful_ocr_result,
          ai_result: successful_ai_result
        )
      )
    end

    it 'AI失敗fallbackでもOCR由来の明細・税内訳・支払い情報を保存する' do
      receipt = create(:receipt, :processing, :with_image)

      described_class.finalize(
        receipt: receipt,
        decision: finalize_decision(
          :ai_fallback,
          ocr_result: rich_ocr_result,
          error_code: 'analysis_missing_keys'
        )
      )
      receipt.reload

      items = receipt.receipt_items.order(:position_index)
      tax_detail = receipt.receipt_tax_details.first
      payment = receipt.receipt_payments.first

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.processing_error_code).to eq('analysis_missing_keys')
        expect(receipt.store_name).to eq('サンプルストア')
        expect(receipt.total_amount).to eq(1280)
        expect(receipt.subtotal_amount).to eq(1164)
        expect(receipt.tax_amount).to eq(116)
        expect(receipt.review_reasons).to be_blank
        expect(items.size).to eq(2)
        expect(items.first.raw_text).to eq('コーヒー')
        expect(items.second.quantity).to eq(BigDecimal('2'))
        expect(receipt.receipt_tax_details.size).to eq(1)
        expect(tax_detail.net_amount).to eq(1164)
        expect(tax_detail.amount).to eq(116)
        expect(tax_detail.rate).to eq(BigDecimal('0.1'))
        expect(receipt.receipt_payments.size).to eq(1)
        expect(payment.method).to eq('CreditCard')
        expect(payment.amount).to eq(1280)
      end
    end

    it 'AI失敗fallbackでは高信頼OCR adjustment candidateを保存しreview_neededにする' do
      receipt = create(:receipt, :processing, :with_image)
      ocr_result = ocr_fixture('delivery_and_bag_fee_receipt')

      described_class.finalize(
        receipt: receipt,
        decision: finalize_decision(:ai_fallback, ocr_result: ocr_result, error_code: 'analysis_missing_keys')
      )
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.processing_error_code).to eq('analysis_missing_keys')
        expect(receipt.receipt_adjustments.pluck(:kind, :amount, :sign, :source)).to contain_exactly(
          [ 'bag_fee', 10, 'surcharge', 'ocr' ],
          [ 'delivery_fee', 550, 'surcharge', 'ocr' ]
        )
        expect(receipt.receipt_adjustments).to all(have_attributes(needs_review: true))
        expect(receipt.review_reasons).to include('adjustment_uncertain')
      end
    end

    it 'AI失敗fallbackではpayment_method_textが空でもpaymentsから代表payment_methodを推定する' do
      receipt = create(:receipt, :processing, :with_image)
      ocr_result = rich_ocr_result(
        raw_text: "サンプルストア\n2026/04/02 12:34\nコーヒー 180\n合計 1280",
        lines: [
          'サンプルストア',
          '2026/04/02 12:34',
          'コーヒー 180',
          '合計 1280'
        ],
        candidates: {
          payment_method_text: nil,
          payments: [
            { method: '現金', amount: 1280 }
          ]
        }
      )

      described_class.finalize(
        receipt: receipt,
        decision: finalize_decision(:ai_fallback, ocr_result: ocr_result, error_code: 'analysis_missing_keys')
      )

      aggregate_failures do
        expect(receipt.reload.payment_method).to eq('cash')
        expect(receipt.receipt_payments.first.method).to eq('現金')
      end
    end

    it 'AI失敗fallbackでも複合paymentsから代表payment_methodを保存する' do
      receipt = create(:receipt, :processing, :with_image)
      ocr_result = rich_ocr_result(
        raw_text: "サンプルストア\n2026/04/02 12:34\nコーヒー 180\n合計 1280",
        lines: [
          'サンプルストア',
          '2026/04/02 12:34',
          'コーヒー 180',
          '合計 1280'
        ],
        candidates: {
          payment_method_text: nil,
          payments: [
            { method: 'ポイント利用', amount: 280 },
            { method: 'VISA Credit', amount: 1000 }
          ]
        }
      )

      described_class.finalize(
        receipt: receipt,
        decision: finalize_decision(:ai_fallback, ocr_result: ocr_result, error_code: 'analysis_missing_keys')
      )

      aggregate_failures do
        expect(receipt.reload.payment_method).to eq('credit_card')
        expect(receipt.receipt_payments.order(:id).pluck(:method, :amount)).to eq([
          [ 'ポイント利用', 280 ],
          [ 'VISA Credit', 1000 ]
        ])
      end
    end

    it 'OCR itemsが空でもlinesからfallbackで明細を生成する' do
      receipt = create(:receipt, :processing, :with_image)
      ocr_result = rich_ocr_result(
        candidates: {
          items: [],
          payments: [],
          tax_details: []
        }
      )

      described_class.finalize(
        receipt: receipt,
        decision: finalize_decision(:ai_fallback, ocr_result: ocr_result, error_code: 'analysis_missing_keys')
      )

      aggregate_failures do
        expect(receipt.reload.status).to eq('review_needed')
        expect(receipt.receipt_items.count).to eq(2)
        expect(receipt.receipt_items.pluck(:raw_text)).to include('コーヒー 180', 'サンド 550 x2')
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

    it '画像保持OFFのfail_receipt完了後にpurge候補化する' do
      receipt = create(:receipt, :processing, :with_image, keep_image: false)

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
        expect(receipt.image_purge_eligible_at).to be_present
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

    it 'snapshot入力でai_success decisionを保存できる' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      ocr_result_with_raw = successful_ocr_result.deep_merge(
        raw_text: '保存しないOCR全文',
        raw_response: '保存しないAzure raw response',
        image: '保存しない画像情報'
      )
      ai_result_with_raw = successful_ai_result.deep_merge(
        prompt: '保存しないprompt全文',
        messages: [ '保存しないmessages' ],
        meta: {
          response_body: '保存しないAI raw response',
          api_key: '保存しないapi key'
        }
      )
      captured_build_params_inputs = []

      ReceiptAnalysisRuns.record_ocr_snapshot(run, ocr_result_with_raw)
      ReceiptAnalysisRuns.record_ai_normalized_result(run, ai_result_with_raw)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [],
          blocking_inconsistencies: [],
          warning_inconsistencies: []
        )
      )
      allow(Analysis::ReceiptBuildParamsService).to receive(:call).and_wrap_original do |original, **kwargs|
        captured_build_params_inputs << kwargs
        original.call(**kwargs)
      end

      described_class.finalize(
        receipt: receipt,
        run: run,
        decision: finalize_decision(:ai_success)
      )

      receipt.reload
      rehydrated_inputs_json = JSON.generate(captured_build_params_inputs)

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.purchased_at).to eq(Time.zone.parse('2026-05-23 10:00:00'))
        expect(receipt.payment_method).to eq('cash')
        expect(captured_build_params_inputs.first[:ocr_result]).not_to have_key(:raw_text)
        expect(rehydrated_inputs_json).not_to include(
          '保存しないOCR全文',
          '保存しないAzure raw response',
          '保存しない画像情報',
          '保存しないprompt全文',
          '保存しないmessages',
          '保存しないAI raw response',
          '保存しないapi key'
        )
      end
    end

    it 'run snapshotがあってもin-memory decision入力を優先する' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      snapshot_ocr_result = successful_ocr_result.deep_merge(
        candidates: {
          store_name: 'Snapshot Store',
          total_amount: 999,
          items: [
            {
              raw_text: 'Snapshot Item',
              line_total: 999,
              confidence: 0.95
            }
          ]
        }
      )
      in_memory_ocr_result = successful_ocr_result.deep_merge(
        candidates: {
          store_name: 'In Memory Store',
          total_amount: 180,
          items: [
            {
              raw_text: 'In Memory Item',
              line_total: 180,
              confidence: 0.95
            }
          ]
        }
      )

      ReceiptAnalysisRuns.record_ocr_snapshot(run, snapshot_ocr_result)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [],
          blocking_inconsistencies: [],
          warning_inconsistencies: []
        )
      )

      described_class.finalize(
        receipt: receipt,
        run: run,
        decision: finalize_decision(:ocr_only, ocr_result: in_memory_ocr_result)
      )

      aggregate_failures do
        expect(receipt.reload.store_name).to eq('In Memory Store')
        expect(receipt.receipt_items.pluck(:raw_text)).to include('In Memory Item')
        expect(receipt.receipt_items.pluck(:raw_text)).not_to include('Snapshot Item')
      end
    end

    it 'snapshot入力でocr_only decisionをreview_needed固定で保存できる' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)

      ReceiptAnalysisRuns.record_ocr_snapshot(run, successful_ocr_result)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [],
          blocking_inconsistencies: [],
          warning_inconsistencies: []
        )
      )

      described_class.finalize(
        receipt: receipt,
        run: run,
        decision: finalize_decision(:ocr_only)
      )

      aggregate_failures do
        expect(receipt.reload.status).to eq('review_needed')
        expect(receipt.processing_error_code).to be_nil
      end
    end

    it 'snapshot入力でai_fallback decisionをreview_needed固定で保存できる' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)

      ReceiptAnalysisRuns.record_ocr_snapshot(run, successful_ocr_result)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [],
          blocking_inconsistencies: [],
          warning_inconsistencies: []
        )
      )

      described_class.finalize(
        receipt: receipt,
        run: run,
        decision: finalize_decision(
          :ai_fallback,
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

    it 'snapshot入力でもfail_receipt decisionはerror mapperを通す' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)

      described_class.finalize(
        receipt: receipt,
        run: run,
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
      end
    end

    it 'truncated flagがtrueのOCR snapshotでもfinalizeできる' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(:receipt_analysis_run, receipt:)
      long_ocr_result = successful_ocr_result.deep_merge(
        lines: Array.new(151) { |index| "line #{index}" },
        candidates: {
          items: Array.new(101) do |index|
            {
              raw_text: "商品#{index} 180",
              line_total: 180,
              confidence: 0.95
            }
          end
        }
      )

      ReceiptAnalysisRuns.record_ocr_snapshot(run, long_ocr_result)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [],
          blocking_inconsistencies: [],
          warning_inconsistencies: []
        )
      )

      described_class.finalize(
        receipt: receipt,
        run: run,
        decision: finalize_decision(:ocr_only)
      )

      aggregate_failures do
        expect(run.reload.ocr_result_snapshot.dig('truncated', 'lines')).to eq(true)
        expect(run.ocr_result_snapshot.dig('truncated', 'items')).to eq(true)
        expect(receipt.reload.status).to eq('review_needed')
      end
    end

    it 'fixtureのOCR snapshot入力でFinalizeが通る' do
      receipt_fixture_names = %w[
        single_tax_receipt
        multiple_tax_receipt
        external_tax_receipt
        long_receipt
        rotated_receipt
        blurred_receipt
        tax_detail_item_conflict_receipt
      ]
      non_receipt_fixture_names = %w[
        non_receipt_doc_type_memo
        non_receipt_empty
        non_receipt_web_page
      ]

      receipt_fixture_names.each do |fixture_name|
        receipt = create(:receipt, :processing, :with_image)
        run = create(:receipt_analysis_run, receipt:)

        ReceiptAnalysisRuns.record_ocr_snapshot(run, ocr_fixture(fixture_name))

        aggregate_failures(fixture_name) do
          expect do
            described_class.finalize(
              receipt: receipt,
              run: run,
              decision: finalize_decision(:ocr_only)
            )
          end.not_to raise_error
          expect(receipt.reload.status).to eq('review_needed')
        end
      end

      non_receipt_fixture_names.each do |fixture_name|
        receipt = create(:receipt, :processing, :with_image)
        run = create(:receipt_analysis_run, receipt:)

        ReceiptAnalysisRuns.record_ocr_snapshot(run, ocr_fixture(fixture_name))

        aggregate_failures(fixture_name) do
          expect do
            described_class.finalize(
              receipt: receipt,
              run: run,
              decision: finalize_decision(
                :fail_receipt,
                error_code: 'receipt_not_detected'
              )
            )
          end.not_to raise_error
          expect(receipt.reload.status).to eq('failed')
          expect(receipt.processing_error_code).to eq('receipt_not_detected')
        end
      end
    end

    it '単一税率レシートはwarningのみで金額を補正する' do
      receipt, amount = run_finalize_ocr_fixture('single_tax_receipt')

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to be_blank
        expect(receipt.total_amount).to eq(770)
        expect(receipt.subtotal_amount).to eq(700)
        expect(receipt.tax_amount).to eq(70)
        expect(receipt.tax_rate).to eq(BigDecimal('0.1'))
        expect(receipt.receipt_tax_details.pluck(:net_amount, :amount, :rate)).to eq([[ 700, 70, BigDecimal('0.1') ]])
        expect(amount[:needs_review]).to be(false)
        expect(amount[:mismatch_codes]).to eq([ 'TAX_DETAIL_INCOMPLETE' ])
        expect(amount[:blocking_inconsistencies]).to be_empty
        expect(amount[:warning_inconsistencies]).to eq([ :tax_detail_incomplete ])
      end
    end

    it '印字された単一10%税内訳が合計全体に一致する場合はAIの軽減税率推定を補正する' do
      receipt = create(:receipt, :processing, :with_image)
      ocr_result = {
        success: true,
        raw_text: "※は軽減税率適用商品\n深夜料(*)\n¥91\n合計\n¥1,391\n(10%対象\n¥1,391内消費税\n¥126)",
        lines: [
          '※は軽減税率適用商品',
          '深夜料(*)',
          '¥91',
          '合計',
          '¥1,391',
          '(10%対象',
          '¥1,391内消費税',
          '¥126)'
        ],
        candidates: {
          store_name: 'サンプル食堂',
          total_amount: 1_391,
          tax_amount: 126,
          tax_rate: 10,
          country_region: 'JPN',
          payment_method_text: 'au PAY',
          items: [
            { raw_text: '牛丼並', price: 450, quantity: 2, line_total: 900, confidence: 0.95 },
            { raw_text: 'サラダセット', price: 200, quantity: 2, line_total: 400, confidence: 0.95 }
          ],
          payments: [
            { method: 'au PAY', amount: 1_391 }
          ],
          tax_details: [
            { description: '内消費税', amount: 126, rate: 10 }
          ]
        },
        meta: {
          confidence_summary: {
            overall: 0.95,
            items_average: 0.95
          }
        }
      }
      ai_result = {
        success: true,
        needs_review: false,
        receipt_attributes: {
          payment_method: 'qr_payment'
        },
        receipt_items_attributes: [
          { index: 0, suggested_name: '牛丼並', category: 'food', tax_rate: 0.08, tax_rate_reason: 'reduced_rate', tax_rate_confidence: 0.98, needs_review: false },
          { index: 1, suggested_name: 'サラダセット', category: 'food', tax_rate: 0.08, tax_rate_reason: 'reduced_rate', tax_rate_confidence: 0.98, needs_review: false }
        ],
        receipt_adjustments_attributes: [
          {
            kind: 'late_night_charge',
            label: '深夜料',
            amount: 91,
            sign: 'surcharge',
            tax_rate: 0.1,
            source_text: '深夜料(*)',
            source_line_index: 1,
            confidence: 0.97,
            needs_review: false,
            review_reasons: []
          }
        ]
      }

      described_class.finalize(
        receipt: receipt,
        decision: finalize_decision(
          :ai_success,
          ocr_result: ocr_result,
          ai_result: ai_result
        )
      )

      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.receipt_items.pluck(:tax_rate)).to eq([ BigDecimal('0.1'), BigDecimal('0.1') ])
        expect(receipt.receipt_adjustments.pluck(:kind, :amount, :tax_rate)).to eq([
          [ 'late_night_charge', 91, BigDecimal('0.1') ]
        ])
        expect(receipt.receipt_tax_details.pluck(:description, :net_amount, :amount, :rate)).to eq([
          [ '10%対象', 1_265, 126, BigDecimal('0.1') ]
        ])
        expect(receipt.subtotal_amount).to eq(1_265)
        expect(receipt.tax_amount).to eq(126)
        expect(receipt.total_amount).to eq(1_391)
        expect(receipt.amount_calculation_profile.dig('profile', 'tax_rate_correction')).to include(
          'reason' => 'single_tax_detail_total_matches_receipt_total',
          'source' => 'printed_tax_detail',
          'rate' => '0.1',
          'item_count' => 2,
          'adjustment_count' => 0
        )
      end
    end

    it '値引き後の税率別対象額が合計に一致する内税レシートは税を足し直さない' do
      receipt = create(:receipt, :processing, :with_image)
      ocr_result = {
        success: true,
        raw_text: "Sample Sweets\nMIX SWEETS\n0.300 kg Net. × 14,400\n4,320 軽\nShort Dated Stock Discount\n-2,160\nアウトレット袋S\n44\n小計 [2]\n2,204\nお預かり\n5,000\nお釣り\n-2,796\n軽 8% ¥2,160 消費税 ¥160\n10% ¥44 消費税 ¥4",
        lines: [
          'Sample Sweets',
          'MIX SWEETS',
          '0.300 kg Net. × 14,400',
          '4,320 軽',
          'Short Dated Stock Discount',
          '-2,160',
          'アウトレット袋S',
          '44',
          '小計 [2]',
          '2,204',
          'お預かり',
          '5,000',
          'お釣り',
          '-2,796',
          '軽 8% ¥2,160 消費税 ¥160',
          '10% ¥44 消費税 ¥4'
        ],
        candidates: {
          store_name: 'Sample Sweets',
          purchased_at_text: '2025/11/03 13:36',
          subtotal_amount: 2_204,
          total_amount: 5_000,
          tax_amount: 164,
          country_region: 'JPN',
          payment_method_text: '現金',
          items: [
            {
              raw_text: 'MIX SWEETS',
              price: 14_400,
              quantity: BigDecimal('0.300'),
              quantity_unit: 'kg',
              line_total: 4_320,
              tax_rate: 8,
              confidence: 0.95
            },
            {
              raw_text: 'Short Dated Stock Discount',
              line_total: -2_160,
              tax_rate: 8,
              confidence: 0.94
            },
            {
              raw_text: 'アウトレット袋S',
              price: 44,
              quantity: 1,
              line_total: 44,
              tax_rate: 10,
              confidence: 0.95
            }
          ],
          payments: [
            { method: 'Cash', amount: 5_000 }
          ],
          tax_details: [
            { description: '軽 8%対象', net_amount: 2_160, amount: 160, rate: 8 },
            { description: '10%対象', net_amount: 44, amount: 4, rate: 10 }
          ]
        },
        meta: {
          confidence_summary: {
            overall: 0.95,
            items_average: 0.95
          }
        }
      }
      ai_result = {
        success: true,
        needs_review: false,
        receipt_attributes: {
          store_name: 'Sample Sweets',
          purchased_at: Time.zone.local(2025, 11, 3, 13, 36, 0),
          payment_method: 'cash'
        },
        receipt_items_attributes: [
          { index: 0, suggested_name: 'MIX SWEETS', category: 'food', tax_rate: 0.08, needs_review: false },
          { index: 2, suggested_name: 'アウトレット袋S', category: 'daily_goods', tax_rate: 0.08, tax_rate_reason: 'reduced_rate', tax_rate_confidence: 0.9, needs_review: false }
        ],
        receipt_adjustments_attributes: [
          {
            kind: 'receipt_discount',
            label: 'Short Dated Stock Discount',
            amount: 2_160,
            sign: 'discount',
            tax_rate: 0.1,
            source_text: 'Short Dated Stock Discount',
            source_line_index: 4,
            confidence: 0.98,
            needs_review: false,
            review_reasons: []
          }
        ]
      }

      described_class.finalize(
        receipt: receipt,
        decision: finalize_decision(
          :ai_success,
          ocr_result: ocr_result,
          ai_result: ai_result
        )
      )

      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.receipt_items.pluck(:suggested_name, :line_total, :tax_rate)).to contain_exactly(
          [ 'MIX SWEETS', 4_320, BigDecimal('0.08') ],
          [ 'アウトレット袋S', 44, BigDecimal('0.1') ]
        )
        expect(receipt.receipt_items.pluck(:raw_text)).not_to include('Short Dated Stock Discount')
        expect(receipt.receipt_adjustments.pluck(:kind, :amount, :sign, :tax_rate)).to eq([
          [ 'receipt_discount', 2_160, 'discount', BigDecimal('0.08') ]
        ])
        expect(receipt.receipt_tax_details.pluck(:description, :net_amount, :amount, :rate)).to contain_exactly(
          [ '8%対象', 2_160, 160, BigDecimal('0.08') ],
          [ '10%対象', 44, 4, BigDecimal('0.1') ]
        )
        expect(receipt.subtotal_amount).to eq(2_204)
        expect(receipt.tax_amount).to eq(164)
        expect(receipt.total_amount).to eq(2_204)
        expect(receipt.amount_calculation_profile.dig('computed', 'tax_detail_amount_basis')).to eq('gross')
        expect(receipt.amount_calculation_profile.dig('resolved', 'total_amount')).to eq(2_204)
        expect(receipt.amount_calculation_profile.dig('profile', 'tax_rate_correction')).to include(
          'reason' => 'tax_detail_amount_match',
          'source' => 'printed_tax_detail',
          'item_count' => 1,
          'adjustment_count' => 1
        )
      end
    end

    it '複数税率の外税レシートは印字税率と税率別対象額でcompletedにする' do
      receipt, amount = run_finalize_ocr_fixture('multiple_tax_receipt')

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to be_blank
        expect(receipt.total_amount).to eq(1732)
        expect(receipt.subtotal_amount).to eq(1598)
        expect(receipt.tax_amount).to eq(134)
        expect(receipt.tax_rate).to be_nil
        expect(receipt.receipt_items.pluck(:tax_rate)).to eq([
          BigDecimal('0.08'),
          BigDecimal('0.08'),
          BigDecimal('0.08'),
          BigDecimal('0.1'),
          BigDecimal('0.1'),
          BigDecimal('0.1')
        ])
        expect(receipt.receipt_tax_details.pluck(:description, :net_amount, :amount, :rate)).to contain_exactly(
          [ '8%対象', 604, 44, BigDecimal('0.08') ],
          [ '10%対象', 994, 90, BigDecimal('0.1') ]
        )
        expect(amount[:needs_review]).to be(false)
        expect(amount[:mismatch_codes]).to eq([ 'PRICE_TAX_INCLUSION_UNCERTAIN' ])
        expect(amount[:blocking_inconsistencies]).to be_empty
        expect(amount[:warning_inconsistencies]).to eq([ :price_tax_inclusion_uncertain ])
        expect(amount.dig(:computed, :tax_detail_amount_basis)).not_to eq(:gross)
      end
    end

    it '1画像内の複数レシート疑いはblocking review reasonとしてreview_neededにする' do
      receipt = create(:receipt, :processing, :with_image)
      ocr_result = ocr_fixture('multi_receipts_in_one_image')
      ai_result = ai_success_result_for(ocr_result)
      captured_amount_result = nil

      allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **kwargs|
        captured_amount_result = original.call(**kwargs)
      end

      expect do
        described_class.finalize(
          receipt: receipt,
          decision: finalize_decision(
            :ai_success,
            ocr_result: ocr_result,
            ai_result: ai_result
          )
        )
      end.not_to change(Receipt, :count)

      receipt.reload

      aggregate_failures do
        expect(ocr_result.dig(:candidates, :review_reasons)).to include('multiple_receipts_suspected')
        expect(receipt.status).to eq('review_needed')
        expect(receipt.review_reasons).to include('multiple_receipts_suspected')
        expect(receipt.receipt_items.count).to eq(6)
        expect(captured_amount_result[:needs_review]).to be(true)
      end
    end

    it '外税レシートはtax_detailsを優先しreview不要にする' do
      receipt, amount = run_finalize_ocr_fixture('external_tax_receipt')
      tax_detail = receipt.receipt_tax_details.first

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to be_blank
        expect(receipt.total_amount).to eq(1535)
        expect(receipt.subtotal_amount).to eq(1418)
        expect(receipt.tax_amount).to eq(117)
        expect(receipt.tax_rate).to be_nil
        expect(tax_detail.net_amount).to eq(1162)
        expect(tax_detail.amount).to eq(92)
        expect(amount[:needs_review]).to be(false)
        expect(amount[:mismatch_codes]).to be_empty
        expect(amount.dig(:computed, :tax_detail_amount_basis)).not_to eq(:gross)
      end
    end

    it 'OCRノイズ由来のocr_low_confidenceとblocking mismatchを保存する' do
      ocr_result = ocr_fixture('ocr_noise_receipt')
      receipt, amount = run_finalize_ocr_fixture(
        'ocr_noise_receipt',
        ai_result: ai_success_result_for(
          ocr_result,
          review_reasons: [ 'ocr_low_confidence' ]
        )
      )

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.review_reasons).to eq([
          'ocr_low_confidence',
          'total_mismatch'
        ])
        expect(receipt.total_amount).to eq(890)
        expect(receipt.subtotal_amount).to eq(890)
        expect(receipt.tax_amount).to eq(71)
        expect(amount[:needs_review]).to be(true)
        expect(amount[:mismatch_codes]).to eq([
          'TOTAL_MISMATCH',
          'TAX_DETAIL_INCOMPLETE'
        ])
        expect(amount[:blocking_inconsistencies]).to eq([ :total_mismatch ])
        expect(amount[:warning_inconsistencies]).to eq([ :tax_detail_incomplete ])
      end
    end

    it 'subtotal欠損レシートはwarningのみでsubtotal/taxを補完する' do
      receipt, amount = run_finalize_ocr_fixture('missing_subtotal_receipt')

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to be_blank
        expect(receipt.total_amount).to eq(2998)
        expect(receipt.subtotal_amount).to eq(2776)
        expect(receipt.tax_amount).to eq(222)
        expect(receipt.tax_rate).to eq(BigDecimal('0.08'))
        expect(receipt.amount_calculation_profile).to include(
          'warnings' => [ 'tax_detail_incomplete' ],
          'warning_mismatch_codes' => [ 'TAX_DETAIL_INCOMPLETE' ],
          'blocking_mismatch_codes' => []
        )
        expect(amount[:needs_review]).to be(false)
        expect(amount[:mismatch_codes]).to eq([ 'TAX_DETAIL_INCOMPLETE' ])
        expect(amount[:blocking_inconsistencies]).to be_empty
        expect(amount[:warning_inconsistencies]).to eq([ :tax_detail_incomplete ])
      end
    end

    it '割引が多いレシートは商品単位値引きとレシート単位値引きを分けて合計を合わせる' do
      receipt, amount = run_finalize_ocr_fixture('discount_heavy_receipt')

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.review_reasons).to eq([ 'adjustment_uncertain' ])
        expect(receipt.total_amount).to eq(571)
        expect(receipt.receipt_items.pluck(:raw_text, :original_line_total, :discount_amount, :line_total)).to eq([
          [ '国産豚こま切れ肉 200g', 398, 50, 348 ],
          [ 'きゅうり 1本', 258, nil, 258 ],
          [ "トマト (大玉)\n1個", 198, nil, 198 ],
          [ 'たまご Mサイズ 6個入', 128, 30, 98 ]
        ])
        expect(receipt.receipt_adjustments.pluck(:kind, :amount, :sign)).to contain_exactly(
          [ 'receipt_discount', 100, 'discount' ],
          [ 'coupon', 200, 'discount' ],
          [ 'receipt_discount', 31, 'discount' ]
        )
        expect(amount.dig(:computed, :adjusted_item_total)).to eq(571)
        expect(amount[:blocking_inconsistencies]).to eq([ :adjustment_uncertain ])
      end
    end

    it 'Azure Totalがお預かり金額でも税内訳合計でtotalを補正する' do
      receipt, amount = run_finalize_ocr_fixture('deposit_total_receipt')

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to be_blank
        expect(receipt.total_amount).to eq(649)
        expect(receipt.total_amount).not_to eq(5_000)
        expect(receipt.subtotal_amount).to eq(601)
        expect(receipt.tax_amount).to eq(48)
        expect(amount[:needs_review]).to be(false)
        expect(amount[:blocking_inconsistencies]).to be_empty
        expect(amount[:warning_inconsistencies]).to eq([ :ocr_total_mismatch, :price_tax_inclusion_uncertain ])
      end
    end

    it 'tax_detailsと明細が矛盾するレシートはwarningのみで保存する' do
      receipt, amount = run_finalize_ocr_fixture('tax_detail_item_conflict_receipt')

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to be_blank
        expect(receipt.total_amount).to eq(301)
        expect(receipt.subtotal_amount).to eq(279)
        expect(receipt.tax_amount).to eq(22)
        expect(amount[:needs_review]).to be(false)
        expect(amount[:blocking_inconsistencies]).to be_empty
        expect(amount[:warning_inconsistencies]).to eq([ :ocr_total_mismatch ])
        expect(amount[:mismatch_codes]).to eq([ 'OCR_TOTAL_MISMATCH' ])
      end
    end
  end
end
