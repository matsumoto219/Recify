require 'rails_helper'

RSpec.describe Admin::SystemSettingsQuery do
  describe '.call' do
    it 'definitionsとDB current valuesを結合して返す' do
      actor = create(:user, :admin)
      create(
        :system_setting,
        key: 'feature.receipt_logo_display_enabled',
        value: SystemSettings.stored_value(true),
        updated_by_user: actor
      )

      result = described_class.call
      record = result.records.find { |item| item[:key] == 'feature.receipt_logo_display_enabled' }

      aggregate_failures do
        expect(result.total_count).to eq(SystemSettings.definitions.size)
        expect(record).to include(
          key: 'feature.receipt_logo_display_enabled',
          category: 'feature_flag',
          value_type: 'boolean',
          current_value: true,
          default_value: false,
          source: 'db',
          editable: true,
          risk_level: 'low',
          updated_by_user_id: actor.id
        )
      end
    end

    it 'filterを適用できる' do
      result = described_class.call(category: 'soft_limit')

      expect(result.records.map { |record| record[:key] }).to eq([ 'limits.receipt_upload_soft_limit' ])
    end

    it 'usage limit filterを適用できる' do
      result = described_class.call(category: 'usage_limit')

      expect(result.records.map { |record| record[:key] }).to contain_exactly(
        'limits.receipt_uploads_per_day',
        'limits.manual_receipts_per_day',
        'limits.receipt_items_per_receipt',
        'limits.receipt_adjustments_per_receipt',
        'limits.receipt_payments_per_receipt',
        'limits.receipt_tax_details_per_receipt',
        'limits.notifications_per_user',
        'limits.batch_files_per_day',
        'limits.ocr_jobs_per_day',
        'limits.ai_jobs_per_day',
        'limits.retry_operations_per_day',
        'limits.guest_receipt_uploads_per_day',
        'limits.guest_manual_receipts_per_day',
        'limits.guest_batch_files_per_day',
        'limits.guest_ocr_jobs_per_day',
        'limits.guest_ai_jobs_per_day',
        'limits.guest_storage_bytes',
        'limits.api_requests_per_minute',
        'limits.api_requests_per_day'
      )
    end

    it 'usage limit safety filterを適用できる' do
      result = described_class.call(category: 'usage_limit_safety')

      expect(result.records.map { |record| record[:key] }).to contain_exactly(
        'limits.max_uploads_per_day',
        'limits.max_ocr_per_day',
        'limits.max_ai_per_day',
        'limits.max_storage_bytes'
      )
    end

    it 'unknown keyは空結果にする' do
      result = described_class.call(key: 'secret.provider_api_key')

      expect(result.records).to be_empty
    end

    it 'raw/prompt/secret系を返さない' do
      result_json = described_class.call.records.to_json

      aggregate_failures do
        expect(result_json).not_to include('RAW OCR RESPONSE')
        expect(result_json).not_to include('FULL PROMPT')
        expect(result_json).not_to include('RAW AI RESPONSE')
        expect(result_json).not_to include('SECRET')
        expect(result_json).not_to include('SENTRY_DSN')
        expect(result_json).not_to include('WEBAUTHN_RP_ID')
      end
    end
  end

  describe '.find' do
    it '定義済みkeyのrecordを返す' do
      record = described_class.find(key: 'limits.receipt_upload_soft_limit')

      expect(record).to include(
        key: 'limits.receipt_upload_soft_limit',
        current_value: 100,
        source: 'default'
      )
    end

    it 'unknown keyはnilを返す' do
      expect(described_class.find(key: 'secret.provider_api_key')).to be_nil
    end
  end
end
