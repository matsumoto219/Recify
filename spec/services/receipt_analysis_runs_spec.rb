require 'rails_helper'

RSpec.describe ReceiptAnalysisRuns do
  include ActiveSupport::Testing::TimeHelpers

  def deep_json(value)
    JSON.generate(value)
  end

  def json_roundtrip(value)
    JSON.parse(JSON.generate(value))
  end

  def jsonable(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, child_value), memo| memo[key.to_s] = jsonable(child_value) }
    when Array
      value.map { |child_value| jsonable(child_value) }
    when BigDecimal
      value.to_s('F')
    when Time, ActiveSupport::TimeWithZone, Date, DateTime
      value.iso8601
    when Symbol
      value.to_s
    else
      value
    end
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

  let(:receipt) { create(:receipt) }

  around do |example|
    travel_to(Time.zone.parse('2026-05-23 10:00:00')) { example.run }
  end

  describe '.start' do
    it '親入口経由でrunを作成する' do
      result = described_class.start(receipt:, source: 'upload')

      aggregate_failures do
        expect(result).to be_created
        expect(result.run).to be_persisted
        expect(result.run.receipt).to eq(receipt)
        expect(result.run.source).to eq('upload')
        expect(result.run.stage).to eq('queued')
        expect(result.run.status).to eq('queued')
        expect(result.run.run_key).to be_present
      end
    end

    it 'active runがある場合は既存runを返す' do
      existing = create(:receipt_analysis_run, receipt:)

      result = described_class.start(receipt:, source: 'upload')

      aggregate_failures do
        expect(result).not_to be_created
        expect(result.run).to eq(existing)
        expect(receipt.receipt_analysis_runs.active.count).to eq(1)
      end
    end

    it 'source / requested_by_user / request_reason / parent_runを保存する' do
      requested_by_user = create(:user)
      parent_run = create(:receipt_analysis_run, :succeeded, receipt:)

      result = described_class.start(
        receipt:,
        source: 'admin_retry',
        requested_by_user:,
        request_reason: 'ユーザー問い合わせ対応',
        parent_run:
      )

      aggregate_failures do
        expect(result.run.source).to eq('admin_retry')
        expect(result.run.requested_by_user).to eq(requested_by_user)
        expect(result.run.request_reason).to eq('ユーザー問い合わせ対応')
        expect(result.run.parent_run).to eq(parent_run)
        expect(result.run.attempt_number).to eq(2)
      end
    end
  end

  describe 'stage tracking' do
    it 'stage開始/終了とlatencyを記録する' do
      run = described_class.start(receipt:, source: 'upload').run
      started_at = Time.zone.parse('2026-05-23 10:01:00')
      finished_at = Time.zone.parse('2026-05-23 10:01:02')

      described_class.start_stage(run, 'ocr', at: started_at, provider: 'azure_document_intelligence', model: 'prebuilt-receipt')
      described_class.finish_stage(run, 'ocr', at: finished_at)
      run.reload

      aggregate_failures do
        expect(run.status).to eq('running')
        expect(run.stage).to eq('ocr_validation')
        expect(run.started_at).to eq(started_at)
        expect(run.ocr_started_at).to eq(started_at)
        expect(run.ocr_finished_at).to eq(finished_at)
        expect(run.ocr_latency_ms).to eq(2000)
        expect(run.ocr_provider).to eq('azure_document_intelligence')
        expect(run.ocr_model).to eq('prebuilt-receipt')
      end
    end

    it 'invalid transitionを明示的に拒否する' do
      run = described_class.start(receipt:, source: 'upload').run

      described_class.start_stage(run, 'ai')

      expect do
        described_class.start_stage(run, 'ocr')
      end.to raise_error(ReceiptAnalysisRuns::InvalidTransition)
    end

    it 'terminal後の変更を拒否する' do
      run = described_class.start(receipt:, source: 'upload').run

      described_class.record_final_result(
        run,
        receipt_attributes: { status: 'completed', total_amount: 1280 },
        items_attributes: [ { raw_text: 'コーヒー' } ]
      )
      described_class.succeed(run)

      expect do
        described_class.start_stage(run, 'ai')
      end.to raise_error(ReceiptAnalysisRuns::TerminalRunError)
    end
  end

  describe 'result tracking' do
    it 'OCR provider/model/summaryを記録する' do
      run = described_class.start(receipt:, source: 'upload').run
      ocr_result = {
        success: true,
        raw_text: 'RAW OCR TEXT',
        lines: [ '店名', '合計 1280' ],
        candidates: {
          store_name: 'テストストア',
          total_amount: 1280,
          payment_method_text: 'クレジット',
          country_region: 'JPN',
          items: [ { raw_text: 'コーヒー', line_total: 180 } ],
          payments: [ { method: 'CreditCard' } ],
          tax_details: [ { rate: 0.1, amount: 116 } ],
          confidence_summary: { overall: 0.95, items_average: 0.9 }
        },
        meta: {
          provider: 'azure_document_intelligence',
          model_id: 'prebuilt-receipt',
          polling_metrics: {
            elapsed_ms: 3200,
            poll_count: 3,
            final_status: 'succeeded',
            max_poll_count: 20,
            poll_interval: 1.0,
            total_poll_sleep_ms: 5500,
            max_poll_interval: 3.0,
            poll_backoff_factor: 1.5,
            reached_max_poll: false,
            retry_after_used: true,
            retry_count: 1
          },
          raw_response: { secret: 'do-not-store' }
        }
      }

      described_class.record_ocr_result(run, ocr_result, latency_ms: 1234)
      described_class.record_ocr_snapshot(run, ocr_result)
      run.reload

      aggregate_failures do
        expect(run.stage).to eq('ocr_validation')
        expect(run.ocr_latency_ms).to eq(1234)
        expect(run.ocr_provider).to eq('azure_document_intelligence')
        expect(run.ocr_model).to eq('prebuilt-receipt')
        expect(run.ocr_summary).to include(
          'schema_version' => 'receipt_analysis_run_ocr_summary_v1',
          'success' => true,
          'line_count' => 2,
          'item_count' => 1,
          'payment_count' => 1,
          'tax_detail_count' => 1
        )
        expect(run.ocr_summary['polling_metrics']).to include(
          'elapsed_ms' => 3200,
          'poll_count' => 3,
          'final_status' => 'succeeded',
          'max_poll_count' => 20,
          'poll_interval' => 1.0,
          'total_poll_sleep_ms' => 5500,
          'max_poll_interval' => 3.0,
          'poll_backoff_factor' => 1.5,
          'reached_max_poll' => false,
          'retry_after_used' => true,
          'retry_count' => 1
        )
        expect(run.ocr_result_snapshot.dig('meta', 'polling_metrics')).to include(
          'poll_count' => 3,
          'final_status' => 'succeeded',
          'total_poll_sleep_ms' => 5500,
          'retry_after_used' => true
        )
        expect(deep_json(run.ocr_summary)).not_to include('RAW OCR TEXT')
        expect(deep_json(run.ocr_summary)).not_to include('do-not-store')
      end
    end

    it 'OCR normalized snapshotをfixtureから保存再現できる形で記録する' do
      fixture_names = %w[
        single_tax_receipt
        multiple_tax_receipt
        external_tax_receipt
        long_receipt
        rotated_receipt
        blurred_receipt
        tax_detail_item_conflict_receipt
        non_receipt_doc_type_memo
        non_receipt_empty
        non_receipt_web_page
      ]

      fixture_names.each do |fixture_name|
        ocr_result = ocr_fixture(fixture_name)
        run = described_class.start(receipt: create(:receipt), source: 'upload').run
        expected_params = Analysis::ReceiptBuildParamsService.call(ocr_result: ocr_result, ai_result: nil)

        described_class.record_ocr_snapshot(run, ocr_result)

        snapshot = json_roundtrip(run.reload.ocr_result_snapshot)
        actual_params = Analysis::ReceiptBuildParamsService.call(ocr_result: snapshot, ai_result: nil)

        aggregate_failures(fixture_name) do
          expect(snapshot['schema_version']).to eq('receipt_analysis_run_ocr_result_v1')
          expect(snapshot).not_to have_key('raw_text')
          expect(snapshot['lines']).to be_an(Array)
          expect(jsonable(actual_params)).to eq(jsonable(expected_params))
        end
      end
    end

    it 'OCR normalized snapshotはtop-level raw textやraw responseを保存しない' do
      run = described_class.start(receipt:, source: 'upload').run
      ocr_result = {
        success: true,
        raw_text: 'FULL RAW OCR TEXT MUST NOT BE STORED',
        lines: [ 'テストストア', 'コーヒー 180', '合計 180' ],
        candidates: {
          store_name: 'テストストア',
          total_amount: 180,
          items: [ { raw_text: 'コーヒー', line_total: 180 } ],
          payments: [ { method: 'Cash', amount: 180 } ],
          tax_details: [ { rate: 0.1, amount: 16, net_amount: 164 } ]
        },
        meta: {
          provider: 'azure_document_intelligence',
          model_id: 'prebuilt-receipt',
          raw_response: { secret: 'do-not-store' },
          signed_id: 'do-not-store'
        }
      }

      described_class.record_ocr_snapshot(run, ocr_result)
      snapshot = run.reload.ocr_result_snapshot
      snapshot_json = deep_json(snapshot)

      aggregate_failures do
        expect(snapshot['lines']).to eq([ 'テストストア', 'コーヒー 180', '合計 180' ])
        expect(snapshot.dig('candidates', 'items', 0, 'raw_text')).to eq('コーヒー')
        expect(snapshot_json).not_to include('FULL RAW OCR TEXT MUST NOT BE STORED')
        expect(snapshot_json).not_to include('do-not-store')
        expect(snapshot).not_to have_key('raw_text')
      end
    end

    it 'OCR normalized snapshotはlines/items/payments/tax_detailsの上限とtruncated flagsを持つ' do
      run = described_class.start(receipt:, source: 'upload').run
      ocr_result = {
        success: true,
        lines: Array.new(151) { |index| "#{index}-#{'a' * 600}" },
        candidates: {
          items: Array.new(101) { |index| { raw_text: "商品#{index}", line_total: index } },
          payments: Array.new(21) { |index| { method: "支払い#{index}", amount: index } },
          tax_details: Array.new(21) { |index| { description: "税#{index}", rate: 0.1, amount: index, net_amount: index * 10 } }
        }
      }

      described_class.record_ocr_snapshot(run, ocr_result)
      snapshot = run.reload.ocr_result_snapshot

      aggregate_failures do
        expect(snapshot['lines'].size).to eq(150)
        expect(snapshot['lines'].first.bytesize).to be <= 500
        expect(snapshot.dig('candidates', 'items').size).to eq(100)
        expect(snapshot.dig('candidates', 'payments').size).to eq(20)
        expect(snapshot.dig('candidates', 'tax_details').size).to eq(20)
        expect(snapshot.dig('truncated', 'lines')).to eq(true)
        expect(snapshot.dig('truncated', 'items')).to eq(true)
        expect(snapshot.dig('truncated', 'payments')).to eq(true)
        expect(snapshot.dig('truncated', 'tax_details')).to eq(true)
      end
    end

    it 'AI input snapshotをtruncateし件数上限を守る' do
      run = described_class.start(receipt:, source: 'upload').run
      long_filtered_content = 'あ' * 9_000
      ai_input = {
        filtered_content: long_filtered_content,
        prompt: 'FULL PROMPT MUST NOT BE STORED',
        response_body: 'RAW RESPONSE MUST NOT BE STORED',
        store: {
          store_name: 'テストストア',
          store_candidates: Array.new(12) { |index| "店舗候補#{index}" }
        },
        full_context_lines: Array.new(155) do |index|
          {
            index: index,
            text: "OCR行#{index}",
            previous_text: "前行#{index}",
            next_text: "次行#{index}"
          }
        end,
        purchase: {
          purchased_at_candidates: Array.new(7) { |index| "2026/05/2#{index} 10:00" }
        },
        payment: {
          payment_candidates: Array.new(12) { |index| { method: "支払い#{index}", secret: 'drop-me' } }
        },
        tax: {
          tax_details: Array.new(12) { |index| { description: "税#{index}", amount: index } }
        },
        items: Array.new(55) do |index|
          {
            index: index,
            raw_text: "商品#{index}",
            line_total: index * 100,
            matched_content_lines: [ '保存しない周辺行' ]
          }
        end,
        meta: {
          ocr_provider: 'azure_document_intelligence',
          ocr_model: 'prebuilt-receipt',
          item_count: 55
        }
      }

      described_class.record_ai_input(run, ai_input)
      snapshot = run.reload.ai_input_snapshot
      snapshot_json = deep_json(snapshot)

      aggregate_failures do
        expect(snapshot['schema_version']).to eq('receipt_analysis_run_ai_input_v1')
        expect(snapshot['prompt_schema_version']).to eq('recify_receipt_analysis_v1')
        expect(snapshot['filtered_content'].bytesize).to be <= 8 * 1024
        expect(snapshot.dig('truncated', 'filtered_content')).to eq(true)
        expect(snapshot.dig('truncated', 'items')).to eq(true)
        expect(snapshot.dig('truncated', 'full_context_lines')).to eq(true)
        expect(snapshot['full_context_lines'].size).to eq(150)
        expect(snapshot['items'].size).to eq(50)
        expect(snapshot.dig('store', 'store_candidates').size).to eq(10)
        expect(snapshot.dig('purchase', 'purchased_at_candidates').size).to eq(5)
        expect(snapshot.dig('payment', 'payment_candidates').size).to eq(10)
        expect(snapshot.dig('tax', 'tax_details').size).to eq(10)
        expect(snapshot_json).not_to include('FULL PROMPT MUST NOT BE STORED')
        expect(snapshot_json).not_to include('RAW RESPONSE MUST NOT BE STORED')
        expect(snapshot_json).not_to include('drop-me')
        expect(snapshot_json).not_to include('保存しない周辺行')
      end
    end

    it 'AI normalized snapshotをJSON保存可能な形で記録しraw系を除外する' do
      run = described_class.start(receipt:, source: 'upload').run
      ai_result = {
        success: true,
        needs_review: false,
        error_code: nil,
        review_reasons: Array.new(22) { |index| "reason_#{index}" },
        receipt_attributes: {
          payment_method: 'cash',
          purchased_at: Time.utc(2026, 5, 23, 10, 0, 0),
          total_amount: BigDecimal('180.5')
        },
        receipt_items_attributes: Array.new(101) do |index|
          {
            index: index,
            suggested_name: "商品#{index}",
            category: 'other',
            line_total: BigDecimal('180.5'),
            needs_review: false,
            response_body: 'RAW ITEM RESPONSE MUST NOT BE STORED'
          }
        end,
        prompt: 'FULL PROMPT MUST NOT BE STORED',
        messages: [ 'RAW MESSAGES MUST NOT BE STORED' ],
        meta: {
          provider: 'openai',
          model: 'gpt-test',
          fallback_used: false,
          metrics: {
            provider: 'openai',
            model: 'gpt-test',
            retry_count: 1,
            retry_after_used: true,
            total_retry_sleep_ms: 3000,
            rate_limited: true,
            provider_status: '429',
            token_usage: {
              input_tokens: 123,
              output_tokens: 45,
              total_tokens: 168,
              raw_response: 'RAW TOKEN USAGE MUST NOT BE STORED'
            },
            response_id: 'resp_123',
            fallback_used: false,
            final_provider: 'openai',
            raw_response: 'RAW METRICS MUST NOT BE STORED'
          },
          response_body: 'RAW AI RESPONSE MUST NOT BE STORED',
          api_key: 'SECRET API KEY MUST NOT BE STORED',
          primary_error_message: 'provider raw message should not be stored'
        }
      }

      described_class.record_ai_normalized_result(run, ai_result)
      snapshot = run.reload.ai_normalized_result_snapshot
      snapshot_json = deep_json(snapshot)

      aggregate_failures do
        expect(snapshot['schema_version']).to eq('receipt_analysis_run_ai_normalized_result_v1')
        expect(snapshot['success']).to eq(true)
        expect(snapshot['needs_review']).to eq(false)
        expect(snapshot['review_reasons'].size).to eq(20)
        expect(snapshot['receipt_items_attributes'].size).to eq(100)
        expect(snapshot.dig('receipt_attributes', 'total_amount')).to eq('180.5')
        expect(snapshot.dig('receipt_attributes', 'purchased_at')).to eq('2026-05-23T10:00:00Z')
        expect(snapshot.dig('receipt_items_attributes', 0, 'line_total')).to eq('180.5')
        expect(snapshot.dig('truncated', 'receipt_items_attributes')).to eq(true)
        expect(snapshot.dig('truncated', 'review_reasons')).to eq(true)
        expect(snapshot.dig('meta', 'metrics')).to include(
          'provider' => 'openai',
          'model' => 'gpt-test',
          'retry_count' => 1,
          'retry_after_used' => true,
          'total_retry_sleep_ms' => 3000,
          'rate_limited' => true,
          'provider_status' => '429',
          'response_id' => 'resp_123',
          'fallback_used' => false,
          'final_provider' => 'openai'
        )
        expect(snapshot.dig('meta', 'metrics', 'token_usage')).to eq(
          'input_tokens' => 123,
          'output_tokens' => 45,
          'total_tokens' => 168
        )
        expect { json_roundtrip(snapshot) }.not_to raise_error
        expect(snapshot_json).not_to include('FULL PROMPT MUST NOT BE STORED')
        expect(snapshot_json).not_to include('RAW MESSAGES MUST NOT BE STORED')
        expect(snapshot_json).not_to include('RAW AI RESPONSE MUST NOT BE STORED')
        expect(snapshot_json).not_to include('RAW TOKEN USAGE MUST NOT BE STORED')
        expect(snapshot_json).not_to include('RAW METRICS MUST NOT BE STORED')
        expect(snapshot_json).not_to include('SECRET API KEY MUST NOT BE STORED')
        expect(snapshot_json).not_to include('provider raw message should not be stored')
      end
    end

    it 'AI result provider/model/error/fallback情報をsummaryとして記録する' do
      run = described_class.start(receipt:, source: 'upload').run
      ai_result = {
        success: false,
        needs_review: true,
        error_code: 'ai_primary_failed',
        review_reasons: [ 'response_parse_failed' ],
        receipt_attributes: { store_name: 'AI補正ストア', payment_method: 'credit_card' },
        receipt_items_attributes: [ { index: 0, suggested_name: 'コーヒー' } ],
        meta: {
          provider: 'openai',
          model: 'gpt-test',
          fallback_provider: 'backup-provider',
          fallback_used: true,
          metrics: {
            provider: 'openai',
            model: 'gpt-test',
            elapsed_ms: 1200,
            retry_count: 2,
            retry_after_used: true,
            total_retry_sleep_ms: 4000,
            rate_limited: true,
            provider_status: '429',
            token_usage: {
              input_tokens: 100,
              output_tokens: 20,
              total_tokens: 120
            },
            response_id: 'resp_summary',
            fallback_used: true,
            fallback_provider: 'backup-provider',
            fallback_reason: 'ai_api_error',
            final_provider: 'backup-provider'
          },
          response_body: 'do-not-store'
        }
      }

      described_class.record_ai_result(run, ai_result, latency_ms: 2345)
      run.reload

      aggregate_failures do
        expect(run.stage).to eq('finalize')
        expect(run.ai_latency_ms).to eq(2345)
        expect(run.ai_provider).to eq('openai')
        expect(run.ai_model).to eq('gpt-test')
        expect(run.ai_fallback_provider).to eq('backup-provider')
        expect(run.ai_fallback_used).to eq(true)
        expect(run.ai_result_summary).to include(
          'schema_version' => 'receipt_analysis_run_ai_result_v1',
          'success' => false,
          'error_code' => 'ai_primary_failed',
          'item_count' => 1,
          'metrics' => {
            'provider' => 'openai',
            'model' => 'gpt-test',
            'final_provider' => 'backup-provider',
            'elapsed_ms' => 1200,
            'retry_count' => 2,
            'retry_after_used' => true,
            'total_retry_sleep_ms' => 4000,
            'rate_limited' => true,
            'provider_status' => '429',
            'token_usage' => {
              'input_tokens' => 100,
              'output_tokens' => 20,
              'total_tokens' => 120
            },
            'response_id' => 'resp_summary',
            'fallback_used' => true,
            'fallback_provider' => 'backup-provider',
            'fallback_reason' => 'ai_api_error'
          }
        )
        expect(deep_json(run.ai_result_summary)).not_to include('do-not-store')
      end
    end

    it 'finalize decisionをmetadataにmergeして保存し復元できる' do
      run = described_class.start(receipt:, source: 'upload').run
      run.update!(metadata: { 'operator_note' => 'keep me' })
      decision = finalize_decision(
        :ai_fallback,
        error_code: 'ai_unavailable',
        error_message: 'AI補完に失敗したためOCR結果で保存しました',
        ocr_result: { raw_text: '保存しないOCR全文' },
        ai_result: { messages: [ '保存しないmessages' ] },
        metadata: { reason: 'ai_down', prompt: '保存しないprompt' }
      )

      described_class.record_finalize_decision(run, decision)

      snapshot = run.reload.metadata['finalize_decision']
      restored = ReceiptAnalysisPipeline.finalize_decision_from_snapshot(snapshot)

      aggregate_failures do
        expect(run.metadata['operator_note']).to eq('keep me')
        expect(snapshot).to include(
          'schema_version' => 'receipt_analysis_run_finalize_decision_v1',
          'strategy' => 'ai_fallback',
          'error_code' => 'ai_unavailable',
          'error_message' => 'AI補完に失敗したためOCR結果で保存しました',
          'metadata' => { 'reason' => 'ai_down' }
        )
        expect(snapshot['recorded_at']).to eq(Time.current.iso8601)
        expect(restored.finalize_strategy).to eq('ai_fallback')
        expect(restored.error_code).to eq('ai_unavailable')
        expect(restored.error_message).to eq('AI補完に失敗したためOCR結果で保存しました')
        expect(restored.metadata).to eq('reason' => 'ai_down')
        expect(restored.ocr_result).to be_nil
        expect(restored.ai_result).to be_nil
      end
    end

    it 'finalize decisionのreceipt_attributesとmetadataはallowlistのみ保存する' do
      run = described_class.start(receipt:, source: 'upload').run
      decision = finalize_decision(
        :fail_receipt,
        error_code: 'unsupported_country',
        error_message: 'country_region=USA',
        receipt_attributes: {
          country_region: 'USA',
          store_name: '保存しない店舗名',
          signed_id: '保存しないsigned id'
        },
        metadata: {
          reason: 'unsupported_country',
          response_body: '保存しないraw response',
          api_key: '保存しないapi key'
        }
      )

      described_class.record_finalize_decision(run, decision)

      snapshot = run.reload.metadata['finalize_decision']
      snapshot_json = deep_json(snapshot)
      restored = ReceiptAnalysisPipeline.finalize_decision_from_snapshot(snapshot)

      aggregate_failures do
        expect(snapshot['receipt_attributes']).to eq('country_region' => 'USA')
        expect(snapshot['metadata']).to eq('reason' => 'unsupported_country')
        expect(restored.receipt_attributes).to eq('country_region' => 'USA')
        expect(snapshot_json).not_to include(
          '保存しない店舗名',
          '保存しないsigned id',
          '保存しないraw response',
          '保存しないapi key'
        )
      end
    end

    it 'finalize decisionはraw/prompt/messages/image/secret系を保存しない' do
      run = described_class.start(receipt:, source: 'upload').run
      decision = finalize_decision(
        :fail_receipt,
        error_code: 'unexpected_error',
        error_message: 'prompt sk-secret raw_response Net::ReadTimeout',
        receipt_attributes: {
          country_region: 'JPN',
          image: '保存しないimage',
          blob_key: '保存しないblob key'
        },
        ocr_result: {
          raw_text: '保存しないOCR全文',
          raw_response: '保存しないAzure raw response'
        },
        ai_result: {
          prompt: '保存しないprompt',
          messages: [ '保存しないmessages' ],
          response_body: '保存しないOpenAI raw response'
        },
        metadata: {
          reason: 'unexpected_error',
          token: '保存しないtoken'
        }
      )

      described_class.record_finalize_decision(run, decision)

      snapshot = run.reload.metadata['finalize_decision']
      snapshot_json = deep_json(snapshot)

      aggregate_failures do
        expect(snapshot['error_message']).to be_nil
        expect(snapshot['receipt_attributes']).to eq('country_region' => 'JPN')
        expect(snapshot['metadata']).to eq('reason' => 'unexpected_error')
        expect(snapshot_json).not_to include(
          'sk-secret',
          'raw_response',
          'Net::ReadTimeout',
          '保存しないimage',
          '保存しないblob key',
          '保存しないOCR全文',
          '保存しないAzure raw response',
          '保存しないprompt',
          '保存しないmessages',
          '保存しないOpenAI raw response',
          '保存しないtoken'
        )
      end
    end

    it 'finalize decisionは各strategyを保存/復元できる' do
      cases = [
        finalize_decision(:ai_success),
        finalize_decision(:ocr_only),
        finalize_decision(:ai_fallback, error_code: 'ai_invalid_response'),
        finalize_decision(:fail_receipt, error_code: 'receipt_not_detected')
      ]

      cases.each do |decision|
        run = described_class.start(receipt: create(:receipt), source: 'upload').run

        described_class.record_finalize_decision(run, decision)

        restored = ReceiptAnalysisPipeline.finalize_decision_from_snapshot(run.reload.metadata['finalize_decision'])

        aggregate_failures(decision.finalize_strategy) do
          expect(restored.finalize_strategy).to eq(decision.finalize_strategy)
          expect(restored.error_code).to eq(decision.error_code)
          expect(restored.ocr_result).to be_nil
          expect(restored.ai_result).to be_nil
        end
      end
    end

    it 'final result summaryと成功状態を記録する' do
      run = described_class.start(receipt:, source: 'upload').run
      finalized_at = Time.zone.parse('2026-05-23 10:03:00')

      described_class.record_final_result(
        run,
        receipt_attributes: {
          status: 'review_needed',
          processing_error_code: 'ai_primary_failed',
          review_reasons: [ 'ocr_low_confidence' ],
          total_amount: 1280,
          subtotal_amount: 1164,
          tax_amount: 116
        },
        items_attributes: [ { raw_text: 'コーヒー' }, { raw_text: 'パン' } ],
        payments_attributes: [ { method: 'credit_card' } ],
        tax_details_attributes: [ { rate: 0.1 } ],
        amount_result: {
          mismatch_codes: [ 'TAX_DETAIL_INCOMPLETE' ],
          blocking_mismatch_codes: [],
          warning_mismatch_codes: [ 'TAX_DETAIL_INCOMPLETE' ]
        },
        at: finalized_at
      )
      described_class.succeed(run, at: finalized_at + 1.second)
      run.reload

      aggregate_failures do
        expect(run.status).to eq('succeeded')
        expect(run.stage).to eq('completed')
        expect(run.finished_at).to eq(finalized_at + 1.second)
        expect(run.expires_at).to eq(finalized_at + 1.second + 90.days)
        expect(run.final_result_summary).to include(
          'schema_version' => 'receipt_analysis_run_final_result_v1',
          'receipt_status' => 'review_needed',
          'processing_error_code' => 'ai_primary_failed',
          'item_count' => 2,
          'payment_count' => 1,
          'tax_detail_count' => 1
        )
        expect(run.final_result_summary.dig('amount', 'total_amount')).to eq(1280)
      end
    end

    it 'receipt_status別にsucceeded runのexpires_atを更新する' do
      completed_run = described_class.start(receipt: create(:receipt), source: 'upload').run
      review_needed_run = described_class.start(receipt: create(:receipt), source: 'upload').run
      failed_receipt_run = described_class.start(receipt: create(:receipt), source: 'upload').run
      empty_summary_run = described_class.start(receipt: create(:receipt), source: 'upload').run
      finalized_at = Time.zone.parse('2026-05-23 10:04:00')

      described_class.record_final_result(completed_run, receipt_attributes: { status: 'completed' }, at: finalized_at)
      described_class.record_final_result(review_needed_run, receipt_attributes: { status: 'review_needed' }, at: finalized_at)
      described_class.record_final_result(failed_receipt_run, receipt_attributes: { status: 'failed' }, at: finalized_at)
      described_class.succeed(completed_run, at: finalized_at)
      described_class.succeed(review_needed_run, at: finalized_at)
      described_class.succeed(failed_receipt_run, at: finalized_at)
      described_class.succeed(empty_summary_run, at: finalized_at)

      aggregate_failures do
        expect(completed_run.reload.status).to eq('succeeded')
        expect(completed_run.expires_at).to eq(finalized_at + 30.days)
        expect(review_needed_run.reload.status).to eq('succeeded')
        expect(review_needed_run.expires_at).to eq(finalized_at + 90.days)
        expect(failed_receipt_run.reload.status).to eq('succeeded')
        expect(failed_receipt_run.expires_at).to eq(finalized_at + 90.days)
        expect(empty_summary_run.reload.status).to eq('succeeded')
        expect(empty_summary_run.expires_at).to eq(finalized_at + 30.days)
      end
    end

    it 'failed / superseded / canceled のterminal状態に遷移できる' do
      failed_run = described_class.start(receipt: create(:receipt), source: 'upload').run
      superseded_run = described_class.start(receipt: create(:receipt), source: 'upload').run
      canceled_run = described_class.start(receipt: create(:receipt), source: 'upload').run

      described_class.fail(failed_run, error_stage: 'ai', error_code: 'ai_api_error', error_message: 'x' * 600)
      described_class.supersede(superseded_run)
      described_class.cancel(canceled_run)

      aggregate_failures do
        expect(failed_run.reload.status).to eq('failed')
        expect(failed_run.error_stage).to eq('ai')
        expect(failed_run.error_code).to eq('ai_api_error')
        expect(failed_run.error_message.bytesize).to be <= 500
        expect(superseded_run.reload.status).to eq('superseded')
        expect(canceled_run.reload.status).to eq('canceled')
      end
    end
  end

  describe '.cleanup_stale' do
    it 'dry_runではDBを更新せず対象情報を返す' do
      run = create_stale_run(status: 'queued')

      result = described_class.cleanup_stale(cutoff: 6.hours.ago, dry_run: true)

      aggregate_failures do
        expect(result[:dry_run]).to eq(true)
        expect(result[:stale_count]).to eq(1)
        expect(result[:skipped_count]).to eq(1)
        expect(result[:records]).to contain_exactly(
          include(id: run.id, status: 'queued', stage: 'queued', receipt_status: 'processing')
        )
        expect(run.reload.status).to eq('queued')
        expect(run.receipt.reload.status).to eq('processing')
      end
    end

    it 'queued stale + processing receipt は run failed / receipt failed にする' do
      run = create_stale_run(status: 'queued', stage: 'queued')

      result = described_class.cleanup_stale(cutoff: 6.hours.ago, dry_run: false)
      run.reload

      aggregate_failures do
        expect(result[:failed_count]).to eq(1)
        expect(result[:canceled_count]).to eq(0)
        expect(run.status).to eq('failed')
        expect(run.stage).to eq('queued')
        expect(run.error_code).to eq('analysis_stale_run')
        expect(run.error_stage).to eq('queued')
        expect(run.finished_at).to eq(Time.current)
        expect(run.expires_at).to eq(90.days.from_now)
        expect(run.receipt.reload.status).to eq('failed')
        expect(run.receipt.processing_error_code).to eq('analysis_stale_run')
      end
    end

    it 'running stale + processing receipt は run failed / receipt failed にする' do
      run = create_stale_run(status: 'running', stage: 'ai')

      result = described_class.cleanup_stale(cutoff: 6.hours.ago, dry_run: false)
      run.reload

      aggregate_failures do
        expect(result[:failed_count]).to eq(1)
        expect(run.status).to eq('failed')
        expect(run.stage).to eq('ai')
        expect(run.error_stage).to eq('ai')
        expect(run.receipt.reload.status).to eq('failed')
      end
    end

    it 'stale active runでもreceiptがprocessingでなければ run canceled / receipt不変更にする' do
      receipt = create(:receipt, :completed)
      run = create(:receipt_analysis_run, receipt:, status: 'running', stage: 'finalize')
      run.update_columns(updated_at: 7.hours.ago)

      result = described_class.cleanup_stale(cutoff: 6.hours.ago, dry_run: false)
      run.reload

      aggregate_failures do
        expect(result[:failed_count]).to eq(0)
        expect(result[:canceled_count]).to eq(1)
        expect(run.status).to eq('canceled')
        expect(run.error_code).to be_nil
        expect(run.expires_at).to eq(14.days.from_now)
        expect(receipt.reload.status).to eq('completed')
      end
    end

    it 'terminal run と non-stale active run は対象外にする' do
      stale_terminal = create(:receipt_analysis_run, :failed)
      fresh_active = create(:receipt_analysis_run, status: 'queued')
      stale_terminal.update_columns(updated_at: 7.hours.ago)
      fresh_active.update_columns(updated_at: 1.hour.ago)

      result = described_class.cleanup_stale(cutoff: 6.hours.ago, dry_run: false)

      aggregate_failures do
        expect(result[:stale_count]).to eq(0)
        expect(stale_terminal.reload.status).to eq('failed')
        expect(fresh_active.reload.status).to eq('queued')
      end
    end

    it 'limitを守る' do
      create_stale_run(status: 'queued')
      create_stale_run(status: 'queued')

      result = described_class.cleanup_stale(cutoff: 6.hours.ago, limit: 1, dry_run: false)

      aggregate_failures do
        expect(result[:stale_count]).to eq(1)
        expect(ReceiptAnalysisRun.active.count).to eq(1)
      end
    end

    it 'cleanup後にRetryService eligibilityのactive_run_existsが解除される' do
      run = create_stale_run(status: 'queued')
      before_options = Analysis.retry_eligibility(receipt: run.receipt, parent_run: run).retry_options

      described_class.cleanup_stale(cutoff: 6.hours.ago, dry_run: false)

      after_options = Analysis.retry_eligibility(receipt: run.receipt.reload, parent_run: run.reload).retry_options

      aggregate_failures do
        expect(before_options).to all(include(possible: false, disabled_reason: 'active_run_exists'))
        expect(after_options.find { |option| option[:type] == 'full_reanalyze' }).to include(possible: true, disabled_reason: nil)
        expect(after_options.find { |option| option[:type] == 'ocr_retry' }).to include(possible: true, disabled_reason: nil)
      end
    end

    it 'latest run failed + old processing receipt はstuck processingとしてfailedへ同期する' do
      receipt = create_old_processing_receipt
      latest_run = create(:receipt_analysis_run, :failed, receipt:, stage: 'ai')

      result = described_class.cleanup_stale(cutoff: 6.hours.ago, dry_run: false)
      receipt.reload

      aggregate_failures do
        expect(result[:stale_count]).to eq(0)
        expect(result[:stuck_processing_count]).to eq(1)
        expect(result[:stuck_processing_failed_count]).to eq(1)
        expect(result[:stuck_processing_records]).to contain_exactly(
          include(
            receipt_id: receipt.id,
            receipt_public_id: receipt.public_id,
            receipt_status: 'failed',
            latest_run_key: latest_run.run_key,
            latest_run_status: 'failed'
          )
        )
        expect(receipt.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('analysis_stale_run')
        expect(receipt.processing_error_message).to eq(I18n.t('receipts.processing_errors.unexpected_failure'))
        expect(receipt.processing_error_message).not_to include('RAW', 'secret', 'backtrace')
        expect(receipt.review_reasons).to eq([])
      end
    end

    it 'latest run canceled / superseded + old processing receipt はfailedへ同期する' do
      canceled_receipt = create_old_processing_receipt
      superseded_receipt = create_old_processing_receipt
      create(:receipt_analysis_run, status: 'canceled', receipt: canceled_receipt)
      create(:receipt_analysis_run, status: 'superseded', receipt: superseded_receipt)

      result = described_class.cleanup_stale(cutoff: 6.hours.ago, dry_run: false)

      aggregate_failures do
        expect(result[:stuck_processing_count]).to eq(2)
        expect(result[:stuck_processing_failed_count]).to eq(2)
        expect(canceled_receipt.reload.status).to eq('failed')
        expect(superseded_receipt.reload.status).to eq('failed')
      end
    end

    it 'runなし + old processing receipt はfailedへ同期する' do
      receipt = create_old_processing_receipt

      result = described_class.cleanup_stale(cutoff: 6.hours.ago, dry_run: false)

      aggregate_failures do
        expect(result[:stuck_processing_count]).to eq(1)
        expect(result[:stuck_processing_failed_count]).to eq(1)
        expect(result[:stuck_processing_records]).to contain_exactly(
          include(
            receipt_id: receipt.id,
            latest_run_key: nil,
            latest_run_status: nil
          )
        )
        expect(receipt.reload.status).to eq('failed')
      end
    end

    it 'new processing receipt はstuck processing対象外にする' do
      receipt = create(:receipt, :with_image, :processing)

      result = described_class.cleanup_stale(cutoff: 6.hours.ago, dry_run: false)

      aggregate_failures do
        expect(result[:stuck_processing_count]).to eq(0)
        expect(receipt.reload.status).to eq('processing')
      end
    end

    it 'active queued/running runありのprocessing receiptはstuck processing側では触らない' do
      receipt = create_old_processing_receipt
      active_run = create(:receipt_analysis_run, receipt:, status: 'queued', stage: 'queued')
      active_run.update_columns(updated_at: 1.hour.ago)

      result = described_class.cleanup_stale(cutoff: 6.hours.ago, dry_run: false)

      aggregate_failures do
        expect(result[:stale_count]).to eq(0)
        expect(result[:stuck_processing_count]).to eq(0)
        expect(receipt.reload.status).to eq('processing')
        expect(active_run.reload.status).to eq('queued')
      end
    end

    it 'stuck processing dry_runでは更新せず件数だけ返す' do
      receipt = create_old_processing_receipt
      create(:receipt_analysis_run, :failed, receipt:)

      result = described_class.cleanup_stale(cutoff: 6.hours.ago, dry_run: true)

      aggregate_failures do
        expect(result[:stuck_processing_count]).to eq(1)
        expect(result[:stuck_processing_skipped_count]).to eq(1)
        expect(result[:stuck_processing_failed_count]).to eq(0)
        expect(result[:stuck_processing_records]).to contain_exactly(
          include(receipt_id: receipt.id, receipt_status: 'processing')
        )
        expect(receipt.reload.status).to eq('processing')
      end
    end
  end

  describe '.cleanup_expired' do
    it 'dry_runでは削除せず対象情報を返す' do
      expired = create(:receipt_analysis_run, :succeeded, expires_at: 1.day.ago)

      result = described_class.cleanup_expired(cutoff: Time.current, dry_run: true)

      aggregate_failures do
        expect(result[:dry_run]).to eq(true)
        expect(result[:expired_count]).to eq(1)
        expect(result[:deleted_count]).to eq(0)
        expect(result[:records]).to contain_exactly(include(id: expired.id, status: 'succeeded'))
        expect(ReceiptAnalysisRun.exists?(expired.id)).to be(true)
      end
    end

    it 'terminal expired runを削除する' do
      expired = create(:receipt_analysis_run, :succeeded, expires_at: 1.day.ago)
      retained = create(:receipt_analysis_run, :succeeded, expires_at: 1.day.from_now)

      result = described_class.cleanup_expired(cutoff: Time.current, dry_run: false)

      aggregate_failures do
        expect(result[:expired_count]).to eq(1)
        expect(result[:deleted_count]).to eq(1)
        expect(ReceiptAnalysisRun.exists?(expired.id)).to be(false)
        expect(ReceiptAnalysisRun.exists?(retained.id)).to be(true)
      end
    end

    it 'active expired runは削除しない' do
      active = create(:receipt_analysis_run, status: 'queued', expires_at: 1.day.ago)

      result = described_class.cleanup_expired(cutoff: Time.current, dry_run: false)

      aggregate_failures do
        expect(result[:expired_count]).to eq(0)
        expect(result[:deleted_count]).to eq(0)
        expect(ReceiptAnalysisRun.exists?(active.id)).to be(true)
      end
    end

    it 'limitを守る' do
      create_list(:receipt_analysis_run, 2, :succeeded, expires_at: 1.day.ago)

      result = described_class.cleanup_expired(cutoff: Time.current, limit: 1, dry_run: false)

      aggregate_failures do
        expect(result[:expired_count]).to eq(1)
        expect(result[:deleted_count]).to eq(1)
        expect(ReceiptAnalysisRun.where(status: 'succeeded').count).to eq(1)
      end
    end
  end

  def create_stale_run(status:, stage: 'queued')
    receipt = create(:receipt, :with_image, :processing)
    run = create(:receipt_analysis_run, receipt:, status:, stage:)
    run.update_columns(updated_at: 7.hours.ago)
    run
  end

  def create_old_processing_receipt
    receipt = create(:receipt, :with_image, :processing)
    receipt.update_columns(updated_at: 7.hours.ago)
    receipt
  end
end
