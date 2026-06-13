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

  def with_env(key, value)
    original_value = ENV[key]
    ENV[key] = value
    yield
  ensure
    ENV[key] = original_value
  end
end
