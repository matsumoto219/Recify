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

    it 'カテゴリ順に並べ、同カテゴリ内はkey順にする' do
      result = described_class.call
      ordered_categories = result.records
                                 .map { |record| record[:category] }
                                 .chunk_while { |previous, current| previous == current }
                                 .map(&:first)
      expected_categories = described_class::CATEGORY_ORDER.select do |category|
        SystemSettings.definitions.values.any? { |definition| definition.category == category }
      end

      aggregate_failures do
        expect(ordered_categories).to eq(expected_categories)
        expect(result.records.select { |record| record[:category] == 'usage_limit' }.map { |record| record[:key] })
          .to eq(result.records.select { |record| record[:category] == 'usage_limit' }.map { |record| record[:key] }.sort)
      end
    end

    it '未知カテゴリは既知カテゴリの後ろに並べる' do
      definitions = [
        SystemSettings::Definition.new(
          key: 'zzz.unknown_setting',
          category: 'unknown_category',
          value_type: 'boolean',
          default: false,
          editable: true,
          risk_level: 'low'
        ),
        SystemSettings::Definition.new(
          key: 'security.sample_setting',
          category: 'security',
          value_type: 'boolean',
          default: true,
          editable: true,
          risk_level: 'high'
        ),
        SystemSettings::Definition.new(
          key: 'operations.sample_setting',
          category: 'operation',
          value_type: 'boolean',
          default: true,
          editable: true,
          risk_level: 'high'
        )
      ].index_by(&:key)

      allow(SystemSettings).to receive(:definitions).and_return(definitions)
      allow(SystemSettings).to receive(:fetch) do |key|
        definition = definitions.fetch(key)
        SystemSettings::Entry.new(
          definition: definition,
          current_value: definition.default,
          default_value: definition.default,
          source: 'default'
        )
      end

      result = described_class.call

      expect(result.records.map { |record| record[:key] }).to eq(
        [
          'operations.sample_setting',
          'security.sample_setting',
          'zzz.unknown_setting'
        ]
      )
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
        'limits.batch_upload_max_files',
        'limits.public_announcements_per_page',
        'limits.contact_request_url_count',
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

    it 'amount limit filterを適用できる' do
      result = described_class.call(category: 'amount_limit')

      expect(result.records.map { |record| record[:key] }).to contain_exactly(
        'limits.receipt_total_amount_max',
        'limits.receipt_item_price_max',
        'limits.receipt_item_line_total_max',
        'limits.receipt_tax_amount_max',
        'limits.receipt_adjustment_amount_max',
        'limits.receipt_payment_amount_max'
      )
    end

    it 'analysis quality filterを適用できる' do
      result = described_class.call(category: 'analysis_quality')

      expect(result.records.map { |record| record[:key] }).to contain_exactly(
        'limits.store_name_casing_context_lines_max'
      )
    end

    it 'retention filterを適用できる' do
      result = described_class.call(category: 'retention')

      expect(result.records.map { |record| record[:key] }).to contain_exactly(
        'retention.notifications_read_days',
        'retention.guest_users_days',
        'retention.user_sessions_days',
        'retention.contact_requests_days',
        'retention.analysis_runs_short_days',
        'retention.analysis_runs_default_days',
        'retention.analysis_runs_failed_days',
        'retention.orphan_blobs_hours',
        'retention.receipt_images_days',
        'retention.security_events_critical_days',
        'retention.security_events_high_days',
        'retention.security_events_medium_days',
        'retention.security_events_low_days',
        'retention.audit_logs_high_risk_admin_days',
        'retention.audit_logs_cleanup_execute_days',
        'retention.audit_logs_cleanup_failed_days',
        'retention.audit_logs_passkey_reauth_days',
        'retention.audit_logs_system_dry_run_days',
        'retention.audit_logs_routine_system_days'
      )
    end

    it 'analysis artifact filterを適用できる' do
      result = described_class.call(category: 'analysis_artifact')

      expect(result.records.map { |record| record[:key] }).to contain_exactly(
        'analysis_artifact.ocr_raw_response_capture_enabled',
        'analysis_artifact.ocr_raw_response_max_bytes',
        'analysis_artifact.ocr_raw_response_retention_days'
      )
    end

    it 'risk filterを適用できる' do
      result = described_class.call(risk_level: 'high')

      aggregate_failures do
        expect(result.records).not_to be_empty
        expect(result.records).to all(include(risk_level: 'high'))
      end
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
