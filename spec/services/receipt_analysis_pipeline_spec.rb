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
      allow(ExternalServiceStatus).to receive(:down?).with(:ai).and_return(false)

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
        meta: { provider: 'azure_document_intelligence' }
      }

      allow(ReceiptOcrService).to receive(:call).and_return(ocr_result)

      result = described_class.run_ocr(run)

      aggregate_failures do
        expect(result.next_step).to eq(:finalize)
        expect(result.finalize_decision.finalize_strategy).to eq('fail_receipt')
        expect(result.finalize_decision.error_code).to eq('ocr_timeout')
        expect(run.reload.metadata.dig('finalize_decision', 'strategy')).to eq('fail_receipt')
        expect(run.metadata.dig('finalize_decision', 'error_code')).to eq('ocr_timeout')
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

      allow(ExternalServiceStatus).to receive(:down?).with(:ai).and_return(true)
      down_result = described_class.run_ocr(ai_down_run)

      aggregate_failures('down') do
        expect(down_result.next_step).to eq(:finalize)
        expect(down_result.finalize_decision.finalize_strategy).to eq('ai_fallback')
        expect(down_result.finalize_decision.error_code).to eq('ai_unavailable')
        expect(ai_down_run.reload.metadata.dig('finalize_decision', 'error_code')).to eq('ai_unavailable')
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
  end

  describe 'FinalizeDecision.from_snapshot' do
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

      decision = ReceiptAnalysisPipeline::FinalizeDecision.from_snapshot(snapshot)

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
        expect(ReceiptAnalysisPipeline::FinalizeDecision.from_snapshot(nil)).to be_nil
        expect(
          ReceiptAnalysisPipeline::FinalizeDecision.from_snapshot(
            schema_version: 'old',
            strategy: 'ai_success'
          )
        ).to be_nil
        expect(
          ReceiptAnalysisPipeline::FinalizeDecision.from_snapshot(
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
        expect(receipt.reload.status).to eq('processing')
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
  end
end
