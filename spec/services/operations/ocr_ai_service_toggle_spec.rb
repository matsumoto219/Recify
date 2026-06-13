require 'rails_helper'

RSpec.describe 'OCR/AI operation service toggles', type: :service do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }
  let(:uploaded_file) do
    Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/receipt_sample.jpg'), 'image/jpeg')
  end

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs

    example.run
  ensure
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = original_adapter
  end

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    Rails.cache.clear
  end

  after do
    Rails.cache.clear
  end

  it 'OCR off / AI onではbatch uploadをcounter消費前に拒否しOCR APIを呼ばない' do
    create(:system_setting, key: 'operations.ocr_enabled', value: SystemSettings.stored_value(false))
    allow(ReceiptOcrService).to receive(:call)

    expect do
      result = ReceiptBatchUploadService.call(user: user, files: [ uploaded_file ])

      aggregate_failures do
        expect(result).not_to be_success
        expect(result.errors).to include(I18n.t('flash.receipts.ocr_unavailable'))
      end
    end.not_to change(user.receipts, :count)

    aggregate_failures do
      expect(ReceiptOcrService).not_to have_received(:call)
      expect(ReceiptAnalysisRun.count).to eq(0)
      expect(UsageCounter.where(user: user)).to be_empty
      expect(enqueued_jobs).to be_empty
    end
  end

  it 'OCR on / AI offではAI APIとAI counterを使わずfinalize decisionを保存する' do
    receipt = create(:receipt, :processing, :with_image, user: user)
    run = create(:receipt_analysis_run, receipt: receipt)
    create(:system_setting, key: 'operations.ai_enabled', value: SystemSettings.stored_value(false))
    ReceiptAnalysisRuns.record_ocr_snapshot(run, successful_ocr_result)
    allow(ReceiptAiEnrichmentService).to receive(:call)

    result = ReceiptAnalysisPipeline.run_ai(run)

    aggregate_failures do
      expect(result.next_step).to eq(:finalize)
      expect(result.finalize_decision.error_code).to eq('ai_unavailable')
      expect(ReceiptAiEnrichmentService).not_to have_received(:call)
      expect(UsageCounter.where(user: user, key: 'ai_jobs_per_day')).to be_empty
      expect(run.reload.metadata.dig('finalize_decision', 'error_code')).to eq('ai_unavailable')
    end
  end

  it 'OCR off / AI offでは両サービスをdisabledとして返しuploadを止める' do
    create(:system_setting, key: 'operations.ocr_enabled', value: SystemSettings.stored_value(false))
    create(:system_setting, key: 'operations.ai_enabled', value: SystemSettings.stored_value(false))

    snapshot = ExternalServices.status_snapshot

    aggregate_failures do
      expect(snapshot.dig(:ocr, :state)).to eq('down')
      expect(snapshot.dig(:ocr, :disabled)).to eq(true)
      expect(snapshot.dig(:ocr, :source)).to eq('system_setting')
      expect(snapshot.dig(:ai, :state)).to eq('down')
      expect(snapshot.dig(:ai, :disabled)).to eq(true)
      expect(snapshot.dig(:ai, :source)).to eq('system_setting')
      expect(snapshot.dig(:upload, :allowed)).to eq(false)
      expect(snapshot.dig(:notices, :ocr_down)).to eq(true)
      expect(snapshot.dig(:notices, :ai_down)).to eq(true)
    end
  end

  it 'ENV停止はenv sourceのdisabledとして扱う' do
    with_env(ReceiptAnalysisPipeline::Config::OCR_ENABLED_ENV_KEY, 'false') do
      snapshot = ExternalServices.snapshot(:ocr)

      aggregate_failures do
        expect(snapshot[:state]).to eq('down')
        expect(snapshot[:disabled]).to eq(true)
        expect(snapshot[:source]).to eq('env')
        expect(snapshot[:reason]).to eq(ReceiptAnalysisPipeline::Config::OCR_ENABLED_ENV_KEY)
      end
    end
  end

  it 'StatusStore downはdisabledではない障害状態として扱う' do
    3.times do
      ExternalServices.mark_failure!(:ai, error_code: 'external_service_unavailable')
    end

    snapshot = ExternalServices.snapshot(:ai)

    aggregate_failures do
      expect(snapshot[:state]).to eq('down')
      expect(snapshot[:disabled]).to eq(false)
      expect(snapshot[:source]).to eq('status_store')
      expect(snapshot[:reason]).to eq('external_service_unavailable')
    end
  end

  it 'OCR StatusStore downではpipelineもproviderとcounterを使わずsafe detailを残す' do
    provider_detail = ExternalServices.error_detail(
      service: :ocr,
      provider: 'azure_document_intelligence',
      phase: 'submit',
      http_status: 403,
      provider_error_code: 'QuotaExceeded',
      provider_message_safe: 'F0 quota exceeded for sk-secret-token-1234567890',
      request_id: 'azure-request-id',
      retry_after: 60,
      quota_exceeded: true
    )
    3.times do
      ExternalServices.mark_failure!(
        :ocr,
        error_code: 'external_service_quota_exceeded',
        reason: 'quota_exceeded',
        detail: provider_detail
      )
    end
    receipt = create(:receipt, :processing, :with_image, user: user)
    run = create(:receipt_analysis_run, receipt: receipt)
    allow(ReceiptOcrService).to receive(:call)
    allow(Usage).to receive(:consume_ocr_job!)

    result = ReceiptAnalysisPipeline.run_ocr(run)
    run.reload

    aggregate_failures do
      expect(result.next_step).to eq(:finalize)
      expect(result.finalize_decision.error_code).to eq('ocr_disabled')
      expect(ReceiptOcrService).not_to have_received(:call)
      expect(Usage).not_to have_received(:consume_ocr_job!)
      expect(UsageCounter.where(user: user, key: 'ocr_jobs_per_day')).to be_empty
      expect(run.ocr_result_snapshot.dig('meta', 'provider_error_detail')).to include(
        'source' => 'status_store',
        'reason' => 'quota_exceeded',
        'provider_error_code' => 'QuotaExceeded',
        'quota_exceeded' => true,
        'retry_after' => 60
      )
      expect(run.ocr_result_snapshot.to_json).not_to include('sk-secret-token')
    end
  end

  it 'AI StatusStore downではpipelineもAI APIとcounterを使わずOCR-only finalizeへ進める' do
    3.times do
      ExternalServices.mark_failure!(
        :ai,
        error_code: 'ai_rate_limited',
        reason: 'rate_limited',
        detail: ExternalServices.error_detail(
          service: :ai,
          provider: 'openai',
          phase: 'ai_request',
          http_status: 429,
          provider_error_code: 'rate_limit_exceeded',
          retry_after: 30,
          rate_limited: true
        )
      )
    end
    receipt = create(:receipt, :processing, :with_image, user: user)
    run = create(:receipt_analysis_run, receipt: receipt)
    ReceiptAnalysisRuns.record_ocr_snapshot(run, successful_ocr_result)
    allow(ReceiptAiEnrichmentService).to receive(:call)
    allow(Usage).to receive(:consume_ai_job!)

    result = ReceiptAnalysisPipeline.run_ai(run)

    aggregate_failures do
      expect(result.next_step).to eq(:finalize)
      expect(result.finalize_decision.finalize_strategy).to eq('ai_fallback')
      expect(result.finalize_decision.error_code).to eq('ai_unavailable')
      expect(ReceiptAiEnrichmentService).not_to have_received(:call)
      expect(Usage).not_to have_received(:consume_ai_job!)
      expect(UsageCounter.where(user: user, key: 'ai_jobs_per_day')).to be_empty
      expect(run.reload.metadata.dig('finalize_decision', 'error_code')).to eq('ai_unavailable')
    end
  end

  it 'OCR provider quota exceededはAPI submit到達済みとしてcounterを消費しsafe detailを保存する' do
    receipt = create(:receipt, :processing, :with_image, user: user)
    run = create(:receipt_analysis_run, receipt: receipt)
    provider_detail = ExternalServices.error_detail(
      service: :ocr,
      provider: 'azure_document_intelligence',
      phase: 'submit',
      http_status: 403,
      provider_error_code: 'QuotaExceeded',
      provider_message_safe: 'F0 quota exceeded for sk-secret-token-1234567890',
      request_id: 'azure-request-id',
      quota_exceeded: true
    )
    allow(ReceiptOcrService).to receive(:call) do |_image, before_provider_call:, **_options|
      before_provider_call.call
      {
        success: false,
        error_code: 'external_service_quota_exceeded',
        lines: [],
        candidates: {},
        meta: {
          provider: 'azure_document_intelligence',
          provider_error_detail: provider_detail
        }
      }
    end

    result = ReceiptAnalysisPipeline.run_ocr(run)
    run.reload

    aggregate_failures do
      expect(result.next_step).to eq(:finalize)
      expect(result.finalize_decision.error_code).to eq('external_service_quota_exceeded')
      expect(ReceiptOcrService).to have_received(:call).once
      expect(UsageCounter.find_by!(user: user, key: 'ocr_jobs_per_day').used_count).to eq(1)
      expect(run.ocr_result_snapshot.dig('meta', 'provider_error_detail')).to include(
        'provider_error_code' => 'QuotaExceeded',
        'quota_exceeded' => true
      )
      expect(run.ocr_result_snapshot.to_json).not_to include('sk-secret-token')
    end
  end

  it 'OCR endpoint未設定ではAPI未到達としてOCR counterを消費しない' do
    receipt = create(:receipt, :processing, :with_image, user: user)
    run = create(:receipt_analysis_run, receipt: receipt)

    with_env(
      'AZURE_OCR_ENDPOINT' => nil,
      'AZURE_OCR_API_KEY' => 'test-key'
    ) do
      result = ReceiptAnalysisPipeline.run_ocr(run)

      aggregate_failures do
        expect(result.next_step).to eq(:finalize)
        expect(result.finalize_decision.error_code).to eq('external_service_unavailable')
        expect(UsageCounter.where(user: user, key: 'ocr_jobs_per_day')).to be_empty
        expect(run.reload.ocr_result_snapshot.dig('meta', 'provider_error_detail')).to include(
          'provider_error_code' => 'endpoint_missing'
        )
      end
    end
  end

  it 'OCR key未設定ではAPI未到達としてOCR counterを消費しない' do
    receipt = create(:receipt, :processing, :with_image, user: user)
    run = create(:receipt_analysis_run, receipt: receipt)

    with_env(
      'AZURE_OCR_ENDPOINT' => 'https://example.cognitiveservices.azure.com',
      'AZURE_OCR_API_KEY' => nil
    ) do
      result = ReceiptAnalysisPipeline.run_ocr(run)

      aggregate_failures do
        expect(result.next_step).to eq(:finalize)
        expect(result.finalize_decision.error_code).to eq('external_service_auth_error')
        expect(UsageCounter.where(user: user, key: 'ocr_jobs_per_day')).to be_empty
        expect(run.reload.ocr_result_snapshot.dig('meta', 'provider_error_detail')).to include(
          'provider_error_code' => 'api_key_missing',
          'auth_error' => true
        )
      end
    end
  end

  private

  def successful_ocr_result
    {
      success: true,
      raw_text: "テストストア\nコーヒー 1,000\n合計 1,000",
      lines: [ 'テストストア', 'コーヒー 1,000', '合計 1,000' ],
      candidates: {
        store_name: 'テストストア',
        total_amount: 1_000,
        subtotal_amount: 1_000,
        tax_amount: 0,
        payment_method_text: '現金',
        country_region: 'JPN',
        items: [
          { raw_text: 'コーヒー', price: 1_000, quantity: 1, line_total: 1_000, confidence: 0.95 }
        ],
        payments: [
          { method: 'Cash', amount: 1_000 }
        ],
        tax_details: []
      },
      meta: { provider: 'azure_document_intelligence' }
    }
  end

  def with_env(key_or_overrides, value = nil)
    overrides =
      if key_or_overrides.is_a?(Hash)
        key_or_overrides
      else
        { key_or_overrides => value }
      end
    original_values = overrides.keys.to_h do |key|
      [ key, ENV.key?(key) ? ENV[key] : :__unset__ ]
    end

    overrides.each do |key, override_value|
      override_value.nil? ? ENV.delete(key) : ENV[key] = override_value
    end
    yield
  ensure
    original_values.each do |key, original_value|
      if original_value == :__unset__
        ENV.delete(key)
      else
        ENV[key] = original_value
      end
    end
  end
end
