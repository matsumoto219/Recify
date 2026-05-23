require 'rails_helper'

RSpec.describe ReceiptAnalysisRuns do
  include ActiveSupport::Testing::TimeHelpers

  def deep_json(value)
    JSON.generate(value)
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
          raw_response: { secret: 'do-not-store' }
        }
      }

      described_class.record_ocr_result(run, ocr_result, latency_ms: 1234)
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
        expect(deep_json(run.ocr_summary)).not_to include('RAW OCR TEXT')
        expect(deep_json(run.ocr_summary)).not_to include('do-not-store')
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
          'item_count' => 1
        )
        expect(deep_json(run.ai_result_summary)).not_to include('do-not-store')
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
end
