require 'rails_helper'

RSpec.describe 'Provider error persistence' do
  let(:run) { Receipts::Processing.start(receipt: create(:receipt), source: 'upload').run }
  let(:provider_message) do
    "Invalid\xFF key\0 for person@example.test at https://example.test/private".force_encoding(Encoding::UTF_8)
  end
  let(:provider_detail) do
    {
      service: 'ocr',
      provider: 'azure_document_intelligence',
      phase: 'submit',
      http_status: 403,
      provider_error_code: 'invalid_api_key',
      provider_message_safe: provider_message,
      request_id: 'request-123',
      model: 'x' * 501,
      raw_body: 'private provider body'
    }
  end

  it '構造化された原因をsummary・snapshot・終端記録とretryで短縮しない' do
    allow(Receipts::Processing::Runs::SnapshotBuilder).to receive(:snapshot_string_max_bytes).and_return(100)
    detail = ExternalServices.error_detail(
      service: :ocr,
      phase: :poll,
      http_status: 200,
      policy_id: 'image_policy',
      retry_after_at: '2026-10-20T12:00:00+09:00',
      body: {
        error: {
          code: 'InvalidRequest',
          message: 'Invalid request. ' * 12,
          innererror: { code: 'InvalidContentLength', message: 'The input image is too large. ' * 30 }
        }
      }
    ).deep_stringify_keys
    result = { success: false, meta: { provider_error_detail: detail } }

    Receipts::Processing.record_ocr_result(run, result)
    Receipts::Processing.record_ocr_snapshot(run, result)
    Receipts::Processing.fail(run, error_stage: 'ocr', error_code: 'ocr_api_error', error_metadata: { provider_detail: detail })
    run.reload

    aggregate_failures do
      expect(run.ocr_summary.fetch('provider_error_detail')).to eq(detail)
      expect(run.ocr_result_snapshot.dig('meta', 'provider_error_detail')).to eq(detail)
      expect(run.metadata.dig('error_metadata', 'provider_detail')).to eq(detail)
      [ run.ocr_summary, run.ocr_result_snapshot ].each do |snapshot|
        expect(Receipts::Processing::Runs::SnapshotBuilder.sanitized_stored_snapshot(snapshot)).to eq(snapshot)
      end
    end
  end

  it 'AIのprimary・fallback・finalの原因を保存と再読込で欠落させない' do
    allow(Receipts::Processing::Runs::SnapshotBuilder).to receive(:snapshot_string_max_bytes).and_return(100)
    detail = ExternalServices.error_detail(
      service: :ai,
      provider: 'openai',
      body: { error: { code: 'invalid_value', type: 'invalid_request_error', param: 'reasoning.effort', message: 'Unsupported reasoning setting. ' * 30 } }
    ).deep_stringify_keys
    keys = %w[primary_error_detail fallback_error_detail final_error_detail]
    result = { success: false, meta: keys.index_with { detail }.merge('metrics' => { 'diagnostic' => detail.fetch('diagnostic') }) }

    Receipts::Processing.record_ai_result(run, result)
    Receipts::Processing.record_ai_normalized_result(run, result)
    run.reload

    aggregate_failures do
      [ run.ai_result_summary, run.ai_normalized_result_snapshot.fetch('meta') ].each do |metadata|
        keys.each do |key|
          expect(metadata.fetch(key)).to eq(detail)
        end
        expect(metadata.dig('metrics', 'diagnostic')).to eq(detail.fetch('diagnostic'))
      end
      [ run.ai_result_summary, run.ai_normalized_result_snapshot ].each do |snapshot|
        expect(Receipts::Processing::Runs::SnapshotBuilder.sanitized_stored_snapshot(snapshot)).to eq(snapshot)
      end
    end
  end

  it 'OCR失敗のsummary・snapshot・終端metadataへ安全な詳細を同じ形式で保存する' do
    ocr_result = { success: false, meta: { provider_error_detail: provider_detail } }

    Receipts::Processing.record_ocr_result(run, ocr_result)
    Receipts::Processing.record_ocr_snapshot(run, ocr_result)
    Receipts::Processing.fail(
      run,
      error_stage: 'ocr',
      error_code: 'external_service_auth_error',
      error_metadata: { provider_detail: provider_detail }
    )
    run.reload

    details = [
      run.ocr_summary.fetch('provider_error_detail'),
      run.ocr_result_snapshot.dig('meta', 'provider_error_detail'),
      run.metadata.dig('error_metadata', 'provider_detail')
    ]

    expect(run.status).to eq('failed')
    expect(run.error_code).to eq('external_service_auth_error')
    expect(details.uniq.size).to eq(1)
    expect(details.first).to include('request_id' => 'request-123', 'provider_error_code' => 'invalid_api_key')
    expect(details.first).not_to have_key('model')
    expect(JSON.generate(details)).not_to include('person@example.test', 'https://example.test/private', 'private provider body', '\\u0000')
  end

  it 'AI metricsとprovider detailの再保存で機密情報や不正encodingを復元しない' do
    ai_result = {
      success: false,
      error_code: 'ai_auth_error',
      meta: {
        final_error_detail: provider_detail.merge(service: 'ai', provider: 'openai', phase: 'ai_request'),
        metrics: { provider: 'openai', provider_message: provider_message, request_id: 'request-123' }
      }
    }

    Receipts::Processing.record_ai_result(run, ai_result)
    Receipts::Processing.record_ai_normalized_result(run, ai_result)
    run.reload

    summary_message = run.ai_result_summary.dig('metrics', 'provider_message')
    expect(summary_message).to eq(run.ai_result_summary.dig('final_error_detail', 'provider_message_safe'))
    expect(summary_message).to eq(run.ai_normalized_result_snapshot.dig('meta', 'metrics', 'provider_message'))
    expect(summary_message).to eq(run.ai_normalized_result_snapshot.dig('meta', 'final_error_detail', 'provider_message_safe'))
    expect(summary_message).not_to match(/[[:cntrl:]]/)
    expect(summary_message).not_to include('person@example.test', 'https://example.test/private')
  end
end
