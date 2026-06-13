require 'rails_helper'

RSpec.describe ExternalServices::StatusSnapshot do
  include ActiveSupport::Testing::TimeHelpers

  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    Rails.cache.clear
  end

  after do
    travel_back
    Rails.cache.clear
  end

  describe '.call' do
    it '初期状態ではupload可能な表示用payloadを返す' do
      payload = described_class.call

      aggregate_failures do
        expect(payload.dig(:ocr, :state)).to eq('ok')
        expect(payload.dig(:ocr, :text)).to eq(I18n.t('shared.service_status.ok'))
        expect(payload.dig(:ocr, :message)).to be_nil
        expect(payload.dig(:ocr, :badge_html)).to be_nil
        expect(payload.dig(:ocr, :disabled)).to eq(false)
        expect(payload.dig(:ocr, :source)).to eq('status_store')
        expect(payload.dig(:ai, :state)).to eq('ok')
        expect(payload.dig(:upload, :allowed)).to eq(true)
        expect(payload.dig(:upload, :ocr_available)).to eq(true)
        expect(payload[:notices]).to eq(
          ocr_down: false,
          ocr_degraded: false,
          ai_down: false,
          ai_degraded: false
        )
      end
    end

    it 'SystemSettingsでOCR停止中ならupload不可とsourceを返す' do
      create(:system_setting, key: 'operations.ocr_enabled', value: SystemSettings.stored_value(false))

      payload = described_class.call

      aggregate_failures do
        expect(payload.dig(:ocr, :state)).to eq('down')
        expect(payload.dig(:ocr, :disabled)).to eq(true)
        expect(payload.dig(:ocr, :source)).to eq('system_setting')
        expect(payload.dig(:ocr, :reason)).to eq('operations.ocr_enabled')
        expect(payload.dig(:upload, :allowed)).to eq(false)
        expect(payload.dig(:upload, :ocr_available)).to eq(false)
        expect(payload.dig(:notices, :ocr_down)).to eq(true)
      end
    end

    it 'ENVでAI停止中ならOCR-only fallback noticeとsourceを返す' do
      with_env('RECEIPT_AI_ENABLED' => 'false') do
        payload = described_class.call

        aggregate_failures do
          expect(payload.dig(:ai, :state)).to eq('down')
          expect(payload.dig(:ai, :disabled)).to eq(true)
          expect(payload.dig(:ai, :source)).to eq('env')
          expect(payload.dig(:ai, :reason)).to eq('RECEIPT_AI_ENABLED')
          expect(payload.dig(:upload, :allowed)).to eq(true)
          expect(payload.dig(:upload, :ocr_available)).to eq(true)
          expect(payload.dig(:notices, :ai_down)).to eq(true)
        end
      end
    end

    it 'OCR down時はupload不可とOCR停止noticeを返す' do
      travel_to(Time.zone.parse('2026-05-23 10:00:00')) do
        3.times do
          ExternalServices::StatusStore.mark_failure!(
            :ocr,
            error_code: 'external_service_quota_exceeded',
            reason: 'quota_exceeded',
            detail: {
              service: 'ocr',
              provider: 'azure_document_intelligence',
              phase: 'submit',
              http_status: 403,
              provider_error_code: 'QuotaExceeded',
              provider_message_safe: 'F0 quota exceeded for sk-secret-token-1234567890',
              request_id: 'azure-request-id',
              retry_after: 60,
              quota_exceeded: true
            }
          )
        end
      end

      payload = described_class.call

      aggregate_failures do
        expect(payload.dig(:ocr, :state)).to eq('down')
        expect(payload.dig(:ocr, :monitoring)).to eq(true)
        expect(payload.dig(:ocr, :checked_at)).to be_present
        expect(payload.dig(:ocr, :last_checked_at)).to eq(payload.dig(:ocr, :checked_at))
        expect(payload.dig(:ocr, :next_check_at)).to be_present
        expect(payload.dig(:ocr, :last_error_code)).to eq('external_service_quota_exceeded')
        expect(payload.dig(:ocr, :last_error_reason)).to eq('quota_exceeded')
        expect(payload.dig(:ocr, :last_error_detail)).to include(
          service: 'ocr',
          provider: 'azure_document_intelligence',
          phase: 'submit',
          http_status: 403,
          provider_error_code: 'QuotaExceeded',
          provider_message_safe: 'F0 quota exceeded for [FILTERED]',
          request_id: 'azure-request-id',
          retry_after: 60,
          quota_exceeded: true
        )
        expect(payload.dig(:ocr, :retry_after)).to eq(60)
        expect(payload.dig(:ocr, :request_id)).to eq('azure-request-id')
        expect(payload.dig(:ocr, :provider_error_code)).to eq('QuotaExceeded')
        expect(payload.dig(:ocr, :provider_message_safe)).to eq('F0 quota exceeded for [FILTERED]')
        expect(payload.dig(:ocr, :quota_exceeded)).to eq(true)
        expect(payload.dig(:ocr, :consecutive_failures)).to eq(3)
        expect(payload.dig(:ocr, :message)).to eq(I18n.t('flash.receipts.ocr_unavailable'))
        expect(payload.dig(:upload, :allowed)).to eq(false)
        expect(payload.dig(:upload, :ocr_available)).to eq(false)
        expect(payload.dig(:notices, :ocr_down)).to eq(true)
        expect(payload.to_s).not_to include('sk-secret-token')
      end
    end

    it 'AI down時はupload可能なままOCR-only fallback noticeを返す' do
      travel_to(Time.zone.parse('2026-05-23 10:00:00')) do
        3.times { ExternalServices::StatusStore.mark_failure!(:ai, error_code: 'external_service_unavailable') }
      end

      payload = described_class.call

      aggregate_failures do
        expect(payload.dig(:ai, :state)).to eq('down')
        expect(payload.dig(:ai, :message)).to eq(I18n.t('receipts.new_upload.ai_down'))
        expect(payload.dig(:upload, :allowed)).to eq(true)
        expect(payload.dig(:upload, :ocr_available)).to eq(true)
        expect(payload.dig(:notices, :ai_down)).to eq(true)
      end
    end
  end

  def with_env(overrides)
    original = overrides.keys.to_h { |key| [ key, ENV[key] ] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
