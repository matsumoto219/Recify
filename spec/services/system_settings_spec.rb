require 'rails_helper'

RSpec.describe SystemSettings do
  describe '.definitions' do
    it 'code-side definition allowlistを返す' do
      expect(described_class.definitions.keys).to contain_exactly(
        'feature.receipt_image_preprocess_enabled',
        'feature.receipt_logo_display_enabled',
        'feature.receipt_image_preprocess',
        'feature.receipt_logo_display',
        'operations.ocr_enabled',
        'operations.ai_enabled',
        'amount_engine.tax_excluded_price_conversion_enabled',
        'amount_engine.max_candidate_snapshot_count',
        'ui.maintenance_notice_enabled',
        'ui.maintenance_notice_title',
        'ui.maintenance_notice_body',
        'maintenance.mode',
        'maintenance.title',
        'maintenance.body',
        'security.admin_passkey_reauth_window_minutes',
        'security_events.max_detections_per_request',
        'security_events.aggregation_window_minutes',
        'security_events.admin_burst_window_minutes',
        'security_events.admin_burst_threshold',
        'external_services.failure_window_minutes',
        'external_services.degraded_failure_threshold',
        'external_services.down_failure_threshold',
        'external_services.recovery_success_threshold',
        'storage.keep_receipt_images_default',
        'storage.usage_warning_percentage',
        'storage.usage_error_percentage',
        'storage.warning_remaining_bytes',
        'storage.error_remaining_bytes',
        'storage.remaining_warning_limit_bytes',
        'storage.global_hard_stop_bytes',
        'storage.global_usage_warning_percentage',
        'storage.global_usage_critical_percentage',
        'limits.receipt_upload_soft_limit',
        'limits.receipt_uploads_per_day',
        'limits.manual_receipts_per_day',
        'limits.receipt_items_per_receipt',
        'limits.receipt_adjustments_per_receipt',
        'limits.receipt_payments_per_receipt',
        'limits.receipt_tax_details_per_receipt',
        'limits.receipt_total_amount_max',
        'limits.receipt_item_price_max',
        'limits.receipt_item_line_total_max',
        'limits.receipt_tax_amount_max',
        'limits.receipt_adjustment_amount_max',
        'limits.receipt_payment_amount_max',
        'limits.notifications_per_user',
        'limits.batch_upload_max_files',
        'limits.public_announcements_per_page',
        'limits.contact_request_url_count',
        'limits.receipt_image_max_file_size_bytes',
        'limits.receipt_image_min_dimension_px',
        'limits.receipt_image_max_dimension_px',
        'limits.announcement_image_max_file_size_bytes',
        'limits.announcement_image_min_dimension_px',
        'limits.announcement_image_max_dimension_px',
        'limits.avatar_image_max_file_size_bytes',
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
        'retention.audit_logs_routine_system_days',
        'limits.max_uploads_per_day',
        'limits.max_ocr_per_day',
        'limits.max_ai_per_day',
        'limits.max_storage_bytes',
        'limits.snapshot_ocr_items_max',
        'limits.snapshot_ai_normalized_items_max',
        'limits.snapshot_ocr_lines_max',
        'limits.snapshot_ai_input_full_context_lines_max',
        'limits.snapshot_ai_input_adjustment_context_lines_max',
        'limits.snapshot_ai_input_filtered_content_max_bytes',
        'limits.snapshot_string_max_bytes',
        'limits.snapshot_ai_input_items_max',
        'limits.snapshot_store_candidates_max',
        'limits.snapshot_purchase_candidates_max',
        'limits.snapshot_payment_candidates_max',
        'limits.snapshot_tax_details_max',
        'limits.snapshot_review_reasons_max',
        'limits.ai_prompt_filtered_content_lines_max',
        'limits.ai_prompt_full_context_lines_max',
        'limits.ai_prompt_raw_text_length_max',
        'limits.ai_prompt_purchase_candidates_max',
        'limits.store_name_casing_context_lines_max',
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

    it 'ENV固定項目をdefinitionに含めない' do
      keys = described_class.definitions.keys.join("\n")

      aggregate_failures do
        expect(keys).not_to include('secret')
        expect(keys).not_to include('api_key')
        expect(keys).not_to include('smtp')
        expect(keys).not_to include('sentry')
        expect(keys).not_to include('webauthn')
        expect(keys).not_to include('database')
        expect(keys).not_to include('provider_timeout')
        expect(keys).not_to include('concurrency')
        expect(keys).not_to include('default_url_options')
      end
    end

    it 'provider credentialや本番ENVに置くべき値をeditable definitionに含めない' do
      forbidden_patterns = [
        /(^|[._-])(secret|password|token|credential|credentials)([._-]|$)/,
        /api_key/,
        /smtp/,
        /webauthn/,
        /database/,
        /endpoint/,
        /openai/,
        /azure/,
        /cloudflare/
      ]
      matching_keys = described_class.definitions.keys.select do |key|
        forbidden_patterns.any? { |pattern| pattern.match?(key) }
      end

      expect(matching_keys).to be_empty
    end

    it '本番運用で調整する数値設定は有限の範囲と範囲内defaultを持つ' do
      bounded_categories = %w[
        amount_engine
        security
        security_event
        external_service_status
        storage_warning
        soft_limit
        usage_limit
        amount_limit
        upload_limit
        retention
        usage_limit_safety
        snapshot_limit
        ai_prompt_limit
        analysis_quality
      ]
      target_definitions = described_class.definitions.values.select do |definition|
        bounded_categories.include?(definition.category) && definition.value_type == 'integer'
      end

      aggregate_failures do
        expect(target_definitions.map(&:key)).to include(
          'limits.receipt_image_max_file_size_bytes',
          'limits.announcement_image_max_file_size_bytes',
          'limits.avatar_image_max_file_size_bytes',
          'retention.security_events_high_days',
          'retention.audit_logs_high_risk_admin_days',
          'external_services.down_failure_threshold',
          'limits.ai_prompt_raw_text_length_max',
          'limits.snapshot_ocr_items_max'
        )

        target_definitions.each do |definition|
          expect(definition.min).not_to be_nil, "#{definition.key} should define min"
          expect(definition.max).not_to be_nil, "#{definition.key} should define max"
          expect(definition.default).to be_between(definition.min, definition.max).inclusive,
            "#{definition.key} default should be within min/max"
        end
      end
    end

    it '本番前提の初期値は危険な大小関係になっていない' do
      values = described_class.definitions.transform_values(&:default)

      aggregate_failures do
        expect(values.fetch('storage.usage_warning_percentage')).to be < values.fetch('storage.usage_error_percentage')
        expect(values.fetch('storage.warning_remaining_bytes')).to be > values.fetch('storage.error_remaining_bytes')
        expect(values.fetch('external_services.degraded_failure_threshold')).to be < values.fetch('external_services.down_failure_threshold')
        expect(values.fetch('retention.analysis_runs_failed_days')).to be >= values.fetch('retention.analysis_runs_default_days')
        expect(values.fetch('retention.analysis_runs_default_days')).to be >= values.fetch('retention.analysis_runs_short_days')
        expect(values.fetch('retention.security_events_critical_days')).to be >= values.fetch('retention.security_events_high_days')
        expect(values.fetch('retention.security_events_high_days')).to be >= values.fetch('retention.security_events_medium_days')
        expect(values.fetch('retention.security_events_medium_days')).to be >= values.fetch('retention.security_events_low_days')
        expect(values.fetch('limits.receipt_items_per_receipt')).to be <= values.fetch('limits.snapshot_ocr_items_max')
        expect(values.fetch('limits.receipt_items_per_receipt')).to be <= values.fetch('limits.snapshot_ai_normalized_items_max')
      end
    end
  end

  describe '.value_for' do
    it 'DB値がない場合はdefaultを返す' do
      expect(described_class.value_for('feature.receipt_logo_display_enabled')).to eq(false)
    end

    it 'レシート画像保持defaultはtrueを返す' do
      expect(described_class.value_for('storage.keep_receipt_images_default')).to eq(true)
    end

    it '税抜単価の税込補正defaultはtrueを返す' do
      expect(described_class.value_for('amount_engine.tax_excluded_price_conversion_enabled')).to eq(true)
    end

    it 'OCR/AI運用停止設定defaultはtrueを返す' do
      aggregate_failures do
        expect(described_class.value_for('operations.ocr_enabled')).to eq(true)
        expect(described_class.value_for('operations.ai_enabled')).to eq(true)
      end
    end

    it 'Amount Engine候補snapshot保存件数defaultは3を返す' do
      expect(described_class.value_for('amount_engine.max_candidate_snapshot_count')).to eq(3)
    end

    it 'お知らせ文言defaultはlocale fallback用の空文字を返す' do
      aggregate_failures do
        expect(described_class.value_for('ui.maintenance_notice_title')).to eq('')
        expect(described_class.value_for('ui.maintenance_notice_body')).to eq('')
      end
    end

    it 'メンテナンス制限defaultはoffとlocale fallback用の空文字を返す' do
      aggregate_failures do
        expect(described_class.value_for('maintenance.mode')).to eq('off')
        expect(described_class.value_for('maintenance.title')).to eq('')
        expect(described_class.value_for('maintenance.body')).to eq('')
      end
    end

    it 'DB値がある場合はcast済みの値を返す' do
      create(
        :system_setting,
        key: 'limits.receipt_upload_soft_limit',
        value: described_class.stored_value('250')
      )

      expect(described_class.value_for('limits.receipt_upload_soft_limit')).to eq(250)
    end

    it 'falseのDB値をdefaultに潰さず返す' do
      create(
        :system_setting,
        key: 'feature.receipt_logo_display_enabled',
        value: described_class.stored_value(false)
      )

      expect(described_class.value_for('feature.receipt_logo_display_enabled')).to eq(false)
      expect(described_class.source_for('feature.receipt_logo_display_enabled')).to eq('db')
    end

    it 'unknown keyは明示エラーにする' do
      expect {
        described_class.value_for('secret.provider_api_key')
      }.to raise_error(SystemSettings::UnknownKeyError)
    end
  end

  describe '.enabled?' do
    it 'unknown keyは明示エラーにする' do
      expect {
        described_class.enabled?('secret.provider_api_key')
      }.to raise_error(SystemSettings::UnknownKeyError)
    end

    it 'boolean keyの有効/無効を返す' do
      create(
        :system_setting,
        key: 'feature.receipt_logo_display_enabled',
        value: described_class.stored_value(true)
      )

      expect(described_class.enabled?('feature.receipt_logo_display_enabled')).to eq(true)
      expect(described_class.enabled?('ui.maintenance_notice_enabled')).to eq(false)
      expect(described_class.enabled?('storage.keep_receipt_images_default')).to eq(true)
    end
  end

  describe '.rollout_enabled?' do
    it 'feature flag defaultはfalse' do
      user = create(:user)

      expect(described_class.rollout_enabled?('feature.receipt_image_preprocess', user: user)).to eq(false)
    end

    it 'enabled falseならallowlistやpercentageに関わらずfalse' do
      user = create(:user)
      create(
        :system_setting,
        key: 'feature.receipt_image_preprocess',
        value: described_class.stored_value(
          'enabled' => false,
          'rollout_percentage' => 100,
          'user_allowlist' => [ user.id ]
        )
      )

      expect(described_class.rollout_enabled?('feature.receipt_image_preprocess', user: user)).to eq(false)
    end

    it 'user_allowlistにuser.idがあればtrue' do
      user = create(:user)
      create(
        :system_setting,
        key: 'feature.receipt_image_preprocess',
        value: described_class.stored_value(
          'enabled' => true,
          'rollout_percentage' => 0,
          'user_allowlist' => [ user.id.to_s ]
        )
      )

      expect(described_class.rollout_enabled?('feature.receipt_image_preprocess', user: user)).to eq(true)
    end

    it 'rollout_percentage 100ならuser nilでもtrue' do
      create(
        :system_setting,
        key: 'feature.receipt_image_preprocess',
        value: described_class.stored_value(
          'enabled' => true,
          'rollout_percentage' => 100,
          'user_allowlist' => []
        )
      )

      expect(described_class.rollout_enabled?('feature.receipt_image_preprocess', user: nil)).to eq(true)
    end

    it 'rollout_percentage 0ならfalse' do
      user = create(:user)
      create(
        :system_setting,
        key: 'feature.receipt_image_preprocess',
        value: described_class.stored_value(
          'enabled' => true,
          'rollout_percentage' => 0,
          'user_allowlist' => []
        )
      )

      expect(described_class.rollout_enabled?('feature.receipt_image_preprocess', user: user)).to eq(false)
    end

    it '1..99は同じuser/keyで安定し、user nilはfalse' do
      user = create(:user)
      create(
        :system_setting,
        key: 'feature.receipt_image_preprocess',
        value: described_class.stored_value(
          'enabled' => true,
          'rollout_percentage' => 50,
          'user_allowlist' => []
        )
      )

      first = described_class.rollout_enabled?('feature.receipt_image_preprocess', user: user)
      second = described_class.rollout_enabled?('feature.receipt_image_preprocess', user: user)

      aggregate_failures do
        expect(second).to eq(first)
        expect(described_class.rollout_enabled?('feature.receipt_image_preprocess', user: nil)).to eq(false)
      end
    end

    it 'boolean keyはrollout判定対象外として拒否する' do
      expect {
        described_class.rollout_enabled?('feature.receipt_logo_display_enabled', user: create(:user))
      }.to raise_error(SystemSettings::ValidationError, 'not_feature_flag')
    end
  end

  describe '.limit_for' do
    it 'soft limitをintegerで返す' do
      create(
        :system_setting,
        key: 'limits.receipt_upload_soft_limit',
        value: described_class.stored_value('250')
      )

      expect(described_class.limit_for('limits.receipt_upload_soft_limit')).to eq(250)
    end

    it 'usage limit defaultをintegerで返す' do
      aggregate_failures do
        expect(described_class.limit_for('limits.receipt_uploads_per_day')).to eq(50)
        expect(described_class.limit_for('limits.manual_receipts_per_day')).to eq(50)
        expect(described_class.limit_for('limits.receipt_items_per_receipt')).to eq(100)
        expect(described_class.limit_for('limits.receipt_adjustments_per_receipt')).to eq(50)
        expect(described_class.limit_for('limits.receipt_payments_per_receipt')).to eq(20)
        expect(described_class.limit_for('limits.receipt_tax_details_per_receipt')).to eq(20)
        expect(described_class.limit_for('limits.receipt_total_amount_max')).to eq(999_999_999)
        expect(described_class.limit_for('limits.receipt_item_price_max')).to eq(999_999_999)
        expect(described_class.limit_for('limits.receipt_item_line_total_max')).to eq(999_999_999)
        expect(described_class.limit_for('limits.receipt_tax_amount_max')).to eq(999_999_999)
        expect(described_class.limit_for('limits.receipt_adjustment_amount_max')).to eq(999_999_999)
        expect(described_class.limit_for('limits.receipt_payment_amount_max')).to eq(999_999_999)
        expect(described_class.limit_for('limits.notifications_per_user')).to eq(100)
        expect(described_class.limit_for('limits.batch_upload_max_files')).to eq(5)
        expect(described_class.limit_for('limits.public_announcements_per_page')).to eq(10)
        expect(described_class.limit_for('limits.contact_request_url_count')).to eq(5)
        expect(described_class.limit_for('limits.receipt_image_max_file_size_bytes')).to eq(20.megabytes)
        expect(described_class.limit_for('limits.receipt_image_min_dimension_px')).to eq(100)
        expect(described_class.limit_for('limits.receipt_image_max_dimension_px')).to eq(10_000)
        expect(described_class.limit_for('limits.announcement_image_max_file_size_bytes')).to eq(2.megabytes)
        expect(described_class.limit_for('limits.announcement_image_min_dimension_px')).to eq(100)
        expect(described_class.limit_for('limits.announcement_image_max_dimension_px')).to eq(4096)
        expect(described_class.limit_for('limits.avatar_image_max_file_size_bytes')).to eq(5.megabytes)
        expect(described_class.limit_for('retention.notifications_read_days')).to eq(30)
        expect(described_class.limit_for('retention.guest_users_days')).to eq(7)
        expect(described_class.limit_for('retention.user_sessions_days')).to eq(90)
        expect(described_class.limit_for('retention.contact_requests_days')).to eq(180)
        expect(described_class.limit_for('retention.analysis_runs_short_days')).to eq(14)
        expect(described_class.limit_for('retention.analysis_runs_default_days')).to eq(30)
        expect(described_class.limit_for('retention.analysis_runs_failed_days')).to eq(90)
        expect(described_class.limit_for('retention.orphan_blobs_hours')).to eq(48)
        expect(described_class.limit_for('retention.receipt_images_days')).to eq(1)
        expect(described_class.limit_for('limits.max_uploads_per_day')).to eq(1000)
        expect(described_class.limit_for('limits.max_ocr_per_day')).to eq(1000)
        expect(described_class.limit_for('limits.max_ai_per_day')).to eq(1000)
        expect(described_class.limit_for('limits.max_storage_bytes')).to eq(100.gigabytes)
        expect(described_class.limit_for('storage.global_hard_stop_bytes')).to eq(20.gigabytes)
        expect(described_class.limit_for('storage.global_usage_warning_percentage')).to eq(75)
        expect(described_class.limit_for('storage.global_usage_critical_percentage')).to eq(90)
        expect(described_class.limit_for('limits.snapshot_ocr_items_max')).to eq(1000)
        expect(described_class.limit_for('limits.snapshot_ai_normalized_items_max')).to eq(1000)
        expect(described_class.limit_for('limits.snapshot_ocr_lines_max')).to eq(150)
        expect(described_class.limit_for('limits.snapshot_ai_input_full_context_lines_max')).to eq(150)
        expect(described_class.limit_for('limits.snapshot_ai_input_adjustment_context_lines_max')).to eq(40)
        expect(described_class.limit_for('limits.snapshot_ai_input_filtered_content_max_bytes')).to eq(8.kilobytes)
        expect(described_class.limit_for('limits.snapshot_string_max_bytes')).to eq(500)
        expect(described_class.limit_for('limits.snapshot_ai_input_items_max')).to eq(50)
        expect(described_class.limit_for('limits.snapshot_store_candidates_max')).to eq(10)
        expect(described_class.limit_for('limits.snapshot_purchase_candidates_max')).to eq(5)
        expect(described_class.limit_for('limits.snapshot_payment_candidates_max')).to eq(10)
        expect(described_class.limit_for('limits.snapshot_tax_details_max')).to eq(10)
        expect(described_class.limit_for('limits.snapshot_review_reasons_max')).to eq(20)
        expect(described_class.limit_for('limits.ai_prompt_filtered_content_lines_max')).to eq(40)
        expect(described_class.limit_for('limits.ai_prompt_full_context_lines_max')).to eq(150)
        expect(described_class.limit_for('limits.ai_prompt_raw_text_length_max')).to eq(4000)
        expect(described_class.limit_for('limits.ai_prompt_purchase_candidates_max')).to eq(5)
        expect(described_class.limit_for('limits.batch_files_per_day')).to eq(50)
        expect(described_class.limit_for('limits.ocr_jobs_per_day')).to eq(50)
        expect(described_class.limit_for('limits.ai_jobs_per_day')).to eq(50)
        expect(described_class.limit_for('limits.retry_operations_per_day')).to eq(20)
        expect(described_class.limit_for('limits.guest_receipt_uploads_per_day')).to eq(5)
        expect(described_class.limit_for('limits.guest_manual_receipts_per_day')).to eq(5)
        expect(described_class.limit_for('limits.guest_batch_files_per_day')).to eq(5)
        expect(described_class.limit_for('limits.guest_ocr_jobs_per_day')).to eq(5)
        expect(described_class.limit_for('limits.guest_ai_jobs_per_day')).to eq(5)
        expect(described_class.limit_for('limits.guest_storage_bytes')).to eq(50.megabytes)
        expect(described_class.limit_for('limits.api_requests_per_minute')).to eq(60)
        expect(described_class.limit_for('limits.api_requests_per_day')).to eq(1000)
        expect(described_class.limit_for('storage.usage_warning_percentage')).to eq(80)
        expect(described_class.limit_for('storage.usage_error_percentage')).to eq(95)
        expect(described_class.limit_for('storage.warning_remaining_bytes')).to eq(200.megabytes)
        expect(described_class.limit_for('storage.error_remaining_bytes')).to eq(50.megabytes)
        expect(described_class.limit_for('storage.remaining_warning_limit_bytes')).to eq(1.gigabyte)
        expect(described_class.limit_for('security_events.max_detections_per_request')).to eq(5)
        expect(described_class.limit_for('security_events.aggregation_window_minutes')).to eq(60)
        expect(described_class.limit_for('security_events.admin_burst_window_minutes')).to eq(60)
        expect(described_class.limit_for('security_events.admin_burst_threshold')).to eq(5)
        expect(described_class.limit_for('external_services.failure_window_minutes')).to eq(5)
        expect(described_class.limit_for('external_services.degraded_failure_threshold')).to eq(2)
        expect(described_class.limit_for('external_services.down_failure_threshold')).to eq(3)
        expect(described_class.limit_for('external_services.recovery_success_threshold')).to eq(2)
        expect(described_class.limit_for('retention.security_events_critical_days')).to eq(180)
        expect(described_class.limit_for('retention.security_events_high_days')).to eq(180)
        expect(described_class.limit_for('retention.security_events_medium_days')).to eq(90)
        expect(described_class.limit_for('retention.security_events_low_days')).to eq(30)
        expect(described_class.limit_for('retention.audit_logs_high_risk_admin_days')).to eq(365)
        expect(described_class.limit_for('retention.audit_logs_cleanup_execute_days')).to eq(365)
        expect(described_class.limit_for('retention.audit_logs_cleanup_failed_days')).to eq(180)
        expect(described_class.limit_for('retention.audit_logs_passkey_reauth_days')).to eq(90)
        expect(described_class.limit_for('retention.audit_logs_system_dry_run_days')).to eq(30)
        expect(described_class.limit_for('retention.audit_logs_routine_system_days')).to eq(90)
      end
    end
  end

  describe 'evaluation side effects' do
    it '評価APIはDB更新もAuditLog作成もしない' do
      user = create(:user)

      expect {
        described_class.enabled?('feature.receipt_logo_display_enabled', user: user)
        described_class.rollout_enabled?('feature.receipt_image_preprocess', user: user)
        described_class.limit_for('limits.receipt_upload_soft_limit', user: user)
      }.not_to change { [ SystemSetting.count, AuditLog.count ] }
    end
  end

  describe '.fetch and .source_for' do
    it 'definitionと現在値をEntryで返す' do
      user = create(:user, :admin)
      setting = create(
        :system_setting,
        key: 'ui.maintenance_notice_enabled',
        value: described_class.stored_value(true),
        updated_by_user: user
      )

      entry = described_class.fetch('ui.maintenance_notice_enabled')

      aggregate_failures do
        expect(entry.definition.key).to eq('ui.maintenance_notice_enabled')
        expect(entry.setting).to eq(setting)
        expect(entry.current_value).to eq(true)
        expect(entry.default_value).to eq(false)
        expect(entry.source).to eq('db')
        expect(entry.updated_by_user).to eq(user)
      end
    end
  end

  describe '.editable? and .valid_key?' do
    it 'definitionに基づいて判定する' do
      aggregate_failures do
        expect(described_class.editable?('feature.receipt_logo_display_enabled')).to be(true)
        expect(described_class.valid_key?('feature.receipt_logo_display_enabled')).to be(true)
        expect(described_class.valid_key?('secret.provider_api_key')).to be(false)
      end
    end
  end

  describe '.cast_update_value and .stored_value_for_update' do
    it 'booleanをcastする' do
      expect(described_class.cast_update_value('feature.receipt_logo_display_enabled', '1')).to eq(true)
      expect(described_class.stored_value_for_update('feature.receipt_logo_display_enabled', 'false')).to eq('value' => false)
      expect(described_class.cast_update_value('operations.ocr_enabled', 'false')).to eq(false)
      expect(described_class.stored_value_for_update('operations.ai_enabled', '0')).to eq('value' => false)
    end

    it 'integerのmin/maxを検証する' do
      aggregate_failures do
        expect(described_class.cast_update_value('limits.receipt_upload_soft_limit', '250')).to eq(250)
        expect(described_class.cast_update_value('limits.guest_storage_bytes', 10.megabytes.to_s)).to eq(10.megabytes)
        expect {
          described_class.cast_update_value('limits.receipt_upload_soft_limit', '1001')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect(described_class.cast_update_value('limits.snapshot_ocr_items_max', '100')).to eq(100)
        expect(described_class.cast_update_value('limits.snapshot_ai_normalized_items_max', '10000')).to eq(10_000)
        expect(described_class.cast_update_value('limits.snapshot_ocr_lines_max', '12')).to eq(12)
        expect(described_class.cast_update_value('limits.snapshot_ocr_lines_max', '1000')).to eq(1000)
        expect(described_class.cast_update_value('limits.snapshot_ai_input_full_context_lines_max', '10')).to eq(10)
        expect(described_class.cast_update_value('limits.snapshot_ai_input_full_context_lines_max', '1000')).to eq(1000)
        expect(described_class.cast_update_value('limits.snapshot_ai_input_adjustment_context_lines_max', '10')).to eq(10)
        expect(described_class.cast_update_value('limits.snapshot_ai_input_adjustment_context_lines_max', '500')).to eq(500)
        expect(described_class.cast_update_value('limits.snapshot_ai_input_filtered_content_max_bytes', 1.kilobyte.to_s)).to eq(1.kilobyte)
        expect(described_class.cast_update_value('limits.snapshot_ai_input_filtered_content_max_bytes', 100.kilobytes.to_s)).to eq(100.kilobytes)
        expect(described_class.cast_update_value('limits.snapshot_string_max_bytes', '100')).to eq(100)
        expect(described_class.cast_update_value('limits.snapshot_string_max_bytes', '5000')).to eq(5000)
        expect(described_class.cast_update_value('limits.snapshot_ai_input_items_max', '10')).to eq(10)
        expect(described_class.cast_update_value('limits.snapshot_ai_input_items_max', '5000')).to eq(5000)
        expect(described_class.cast_update_value('limits.snapshot_store_candidates_max', '1')).to eq(1)
        expect(described_class.cast_update_value('limits.snapshot_store_candidates_max', '100')).to eq(100)
        expect(described_class.cast_update_value('limits.snapshot_purchase_candidates_max', '1')).to eq(1)
        expect(described_class.cast_update_value('limits.snapshot_purchase_candidates_max', '50')).to eq(50)
        expect(described_class.cast_update_value('limits.snapshot_payment_candidates_max', '1')).to eq(1)
        expect(described_class.cast_update_value('limits.snapshot_payment_candidates_max', '100')).to eq(100)
        expect(described_class.cast_update_value('limits.snapshot_tax_details_max', '1')).to eq(1)
        expect(described_class.cast_update_value('limits.snapshot_tax_details_max', '100')).to eq(100)
        expect(described_class.cast_update_value('limits.snapshot_review_reasons_max', '1')).to eq(1)
        expect(described_class.cast_update_value('limits.snapshot_review_reasons_max', '100')).to eq(100)
        expect(described_class.cast_update_value('limits.ai_prompt_filtered_content_lines_max', '5')).to eq(5)
        expect(described_class.cast_update_value('limits.ai_prompt_filtered_content_lines_max', '500')).to eq(500)
        expect(described_class.cast_update_value('limits.ai_prompt_full_context_lines_max', '10')).to eq(10)
        expect(described_class.cast_update_value('limits.ai_prompt_full_context_lines_max', '1000')).to eq(1000)
        expect(described_class.cast_update_value('limits.ai_prompt_raw_text_length_max', '500')).to eq(500)
        expect(described_class.cast_update_value('limits.ai_prompt_raw_text_length_max', '50000')).to eq(50_000)
        expect(described_class.cast_update_value('limits.ai_prompt_purchase_candidates_max', '1')).to eq(1)
        expect(described_class.cast_update_value('limits.ai_prompt_purchase_candidates_max', '50')).to eq(50)
        expect(described_class.cast_update_value('limits.store_name_casing_context_lines_max', '0')).to eq(0)
        expect(described_class.cast_update_value('limits.store_name_casing_context_lines_max', '50')).to eq(50)
        expect(described_class.cast_update_value('limits.receipt_adjustments_per_receipt', '0')).to eq(0)
        expect(described_class.cast_update_value('limits.receipt_adjustments_per_receipt', '200')).to eq(200)
        expect(described_class.cast_update_value('limits.receipt_payments_per_receipt', '0')).to eq(0)
        expect(described_class.cast_update_value('limits.receipt_payments_per_receipt', '100')).to eq(100)
        expect(described_class.cast_update_value('limits.receipt_tax_details_per_receipt', '0')).to eq(0)
        expect(described_class.cast_update_value('limits.receipt_tax_details_per_receipt', '100')).to eq(100)
        expect(described_class.cast_update_value('limits.receipt_total_amount_max', '999999999999')).to eq(999_999_999_999)
        expect(described_class.cast_update_value('limits.receipt_item_price_max', '1')).to eq(1)
        expect(described_class.cast_update_value('limits.receipt_tax_amount_max', '1')).to eq(1)
        expect(described_class.cast_update_value('limits.receipt_adjustment_amount_max', '1')).to eq(1)
        expect(described_class.cast_update_value('limits.receipt_payment_amount_max', '1')).to eq(1)
        expect(described_class.cast_update_value('limits.notifications_per_user', '20')).to eq(20)
        expect(described_class.cast_update_value('limits.notifications_per_user', '500')).to eq(500)
        expect(described_class.cast_update_value('limits.batch_upload_max_files', '1')).to eq(1)
        expect(described_class.cast_update_value('limits.batch_upload_max_files', '20')).to eq(20)
        expect(described_class.cast_update_value('limits.public_announcements_per_page', '1')).to eq(1)
        expect(described_class.cast_update_value('limits.public_announcements_per_page', '50')).to eq(50)
        expect(described_class.cast_update_value('limits.contact_request_url_count', '0')).to eq(0)
        expect(described_class.cast_update_value('limits.contact_request_url_count', '20')).to eq(20)
        expect(described_class.cast_update_value('limits.receipt_image_max_file_size_bytes', 1.megabyte.to_s)).to eq(1.megabyte)
        expect(described_class.cast_update_value('limits.receipt_image_max_file_size_bytes', 50.megabytes.to_s)).to eq(50.megabytes)
        expect(described_class.cast_update_value('limits.receipt_image_min_dimension_px', '1')).to eq(1)
        expect(described_class.cast_update_value('limits.receipt_image_min_dimension_px', '5000')).to eq(5000)
        expect(described_class.cast_update_value('limits.receipt_image_max_dimension_px', '1000')).to eq(1000)
        expect(described_class.cast_update_value('limits.receipt_image_max_dimension_px', '20000')).to eq(20_000)
        expect(described_class.cast_update_value('limits.announcement_image_max_file_size_bytes', 100.kilobytes.to_s)).to eq(100.kilobytes)
        expect(described_class.cast_update_value('limits.announcement_image_max_file_size_bytes', 10.megabytes.to_s)).to eq(10.megabytes)
        expect(described_class.cast_update_value('limits.announcement_image_min_dimension_px', '1')).to eq(1)
        expect(described_class.cast_update_value('limits.announcement_image_min_dimension_px', '4096')).to eq(4096)
        expect(described_class.cast_update_value('limits.announcement_image_max_dimension_px', '1000')).to eq(1000)
        expect(described_class.cast_update_value('limits.announcement_image_max_dimension_px', '10000')).to eq(10_000)
        expect(described_class.cast_update_value('limits.avatar_image_max_file_size_bytes', 100.kilobytes.to_s)).to eq(100.kilobytes)
        expect(described_class.cast_update_value('limits.avatar_image_max_file_size_bytes', 20.megabytes.to_s)).to eq(20.megabytes)
        expect(described_class.cast_update_value('storage.usage_warning_percentage', '1')).to eq(1)
        expect(described_class.cast_update_value('storage.usage_warning_percentage', '94')).to eq(94)
        expect(described_class.cast_update_value('storage.usage_error_percentage', '81')).to eq(81)
        expect(described_class.cast_update_value('storage.usage_error_percentage', '100')).to eq(100)
        expect(described_class.cast_update_value('storage.warning_remaining_bytes', 200.megabytes.to_s)).to eq(200.megabytes)
        expect(described_class.cast_update_value('storage.warning_remaining_bytes', 20.gigabytes.to_s)).to eq(20.gigabytes)
        expect(described_class.cast_update_value('storage.error_remaining_bytes', 1.megabyte.to_s)).to eq(1.megabyte)
        expect(described_class.cast_update_value('storage.error_remaining_bytes', 199.megabytes.to_s)).to eq(199.megabytes)
        expect(described_class.cast_update_value('storage.remaining_warning_limit_bytes', 10.megabytes.to_s)).to eq(10.megabytes)
        expect(described_class.cast_update_value('storage.remaining_warning_limit_bytes', 100.gigabytes.to_s)).to eq(100.gigabytes)
        expect(described_class.cast_update_value('storage.global_hard_stop_bytes', 1.gigabyte.to_s)).to eq(1.gigabyte)
        expect(described_class.cast_update_value('storage.global_hard_stop_bytes', 20.terabytes.to_s)).to eq(20.terabytes)
        expect(described_class.cast_update_value('storage.global_usage_warning_percentage', '1')).to eq(1)
        expect(described_class.cast_update_value('storage.global_usage_warning_percentage', '89')).to eq(89)
        expect(described_class.cast_update_value('storage.global_usage_critical_percentage', '76')).to eq(76)
        expect(described_class.cast_update_value('storage.global_usage_critical_percentage', '100')).to eq(100)
        expect(described_class.cast_update_value('security_events.max_detections_per_request', '1')).to eq(1)
        expect(described_class.cast_update_value('security_events.max_detections_per_request', '50')).to eq(50)
        expect(described_class.cast_update_value('security_events.aggregation_window_minutes', '5')).to eq(5)
        expect(described_class.cast_update_value('security_events.aggregation_window_minutes', '1440')).to eq(1440)
        expect(described_class.cast_update_value('security_events.admin_burst_window_minutes', '5')).to eq(5)
        expect(described_class.cast_update_value('security_events.admin_burst_window_minutes', '1440')).to eq(1440)
        expect(described_class.cast_update_value('security_events.admin_burst_threshold', '2')).to eq(2)
        expect(described_class.cast_update_value('security_events.admin_burst_threshold', '100')).to eq(100)
        expect(described_class.cast_update_value('external_services.failure_window_minutes', '1')).to eq(1)
        expect(described_class.cast_update_value('external_services.failure_window_minutes', '60')).to eq(60)
        expect(described_class.cast_update_value('external_services.degraded_failure_threshold', '1')).to eq(1)
        expect(described_class.cast_update_value('external_services.degraded_failure_threshold', '2')).to eq(2)
        expect(described_class.cast_update_value('external_services.down_failure_threshold', '3')).to eq(3)
        expect(described_class.cast_update_value('external_services.down_failure_threshold', '50')).to eq(50)
        expect(described_class.cast_update_value('external_services.recovery_success_threshold', '1')).to eq(1)
        expect(described_class.cast_update_value('external_services.recovery_success_threshold', '20')).to eq(20)
        expect(described_class.cast_update_value('retention.security_events_critical_days', '180')).to eq(180)
        expect(described_class.cast_update_value('retention.security_events_high_days', '180')).to eq(180)
        expect(described_class.cast_update_value('retention.security_events_medium_days', '90')).to eq(90)
        expect(described_class.cast_update_value('retention.security_events_low_days', '30')).to eq(30)
        expect(described_class.cast_update_value('retention.audit_logs_high_risk_admin_days', '365')).to eq(365)
        expect(described_class.cast_update_value('retention.audit_logs_cleanup_execute_days', '365')).to eq(365)
        expect(described_class.cast_update_value('retention.audit_logs_cleanup_failed_days', '180')).to eq(180)
        expect(described_class.cast_update_value('retention.audit_logs_passkey_reauth_days', '90')).to eq(90)
        expect(described_class.cast_update_value('retention.audit_logs_system_dry_run_days', '30')).to eq(30)
        expect(described_class.cast_update_value('retention.audit_logs_routine_system_days', '90')).to eq(90)
        expect(described_class.cast_update_value('retention.notifications_read_days', '1')).to eq(1)
        expect(described_class.cast_update_value('retention.notifications_read_days', '365')).to eq(365)
        expect(described_class.cast_update_value('retention.guest_users_days', '1')).to eq(1)
        expect(described_class.cast_update_value('retention.guest_users_days', '90')).to eq(90)
        expect(described_class.cast_update_value('retention.user_sessions_days', '30')).to eq(30)
        expect(described_class.cast_update_value('retention.user_sessions_days', '365')).to eq(365)
        expect(described_class.cast_update_value('retention.contact_requests_days', '30')).to eq(30)
        expect(described_class.cast_update_value('retention.contact_requests_days', '730')).to eq(730)
        expect(described_class.cast_update_value('retention.analysis_runs_short_days', '1')).to eq(1)
        expect(described_class.cast_update_value('retention.analysis_runs_short_days', '30')).to eq(30)
        expect(described_class.cast_update_value('retention.analysis_runs_default_days', '14')).to eq(14)
        expect(described_class.cast_update_value('retention.analysis_runs_default_days', '90')).to eq(90)
        expect(described_class.cast_update_value('retention.analysis_runs_failed_days', '90')).to eq(90)
        expect(described_class.cast_update_value('retention.analysis_runs_failed_days', '365')).to eq(365)
        expect(described_class.cast_update_value('retention.orphan_blobs_hours', '24')).to eq(24)
        expect(described_class.cast_update_value('retention.orphan_blobs_hours', '720')).to eq(720)
        expect(described_class.cast_update_value('retention.receipt_images_days', '1')).to eq(1)
        expect(described_class.cast_update_value('retention.receipt_images_days', '365')).to eq(365)
        expect(described_class.cast_update_value('limits.max_uploads_per_day', '50')).to eq(50)
        expect(described_class.cast_update_value('limits.max_uploads_per_day', '10000')).to eq(10_000)
        expect(described_class.cast_update_value('limits.max_ocr_per_day', '50')).to eq(50)
        expect(described_class.cast_update_value('limits.max_ocr_per_day', '10000')).to eq(10_000)
        expect(described_class.cast_update_value('limits.max_ai_per_day', '50')).to eq(50)
        expect(described_class.cast_update_value('limits.max_ai_per_day', '10000')).to eq(10_000)
        expect(described_class.cast_update_value('limits.max_storage_bytes', 1.gigabyte.to_s)).to eq(1.gigabyte)
        expect(described_class.cast_update_value('limits.max_storage_bytes', 1.terabyte.to_s)).to eq(1.terabyte)
        expect {
          described_class.cast_update_value('limits.snapshot_ocr_items_max', '99')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.snapshot_ai_normalized_items_max', '10001')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.snapshot_ocr_lines_max', '9')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.snapshot_ocr_lines_max', '1001')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.snapshot_ai_input_full_context_lines_max', '9')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.snapshot_ai_input_full_context_lines_max', '1001')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.snapshot_ai_input_adjustment_context_lines_max', '9')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.snapshot_ai_input_adjustment_context_lines_max', '501')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.snapshot_ai_input_filtered_content_max_bytes', (1.kilobyte - 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.snapshot_ai_input_filtered_content_max_bytes', (100.kilobytes + 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.snapshot_string_max_bytes', '99')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.snapshot_string_max_bytes', '5001')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.snapshot_ai_input_items_max', '9')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.snapshot_ai_input_items_max', '5001')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.snapshot_store_candidates_max', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.snapshot_store_candidates_max', '101')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.snapshot_purchase_candidates_max', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.snapshot_purchase_candidates_max', '51')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.snapshot_payment_candidates_max', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.snapshot_payment_candidates_max', '101')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.snapshot_tax_details_max', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.snapshot_tax_details_max', '101')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.snapshot_review_reasons_max', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.snapshot_review_reasons_max', '101')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.ai_prompt_filtered_content_lines_max', '4')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.ai_prompt_filtered_content_lines_max', '501')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.ai_prompt_full_context_lines_max', '9')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.ai_prompt_full_context_lines_max', '1001')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.ai_prompt_raw_text_length_max', '499')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.ai_prompt_raw_text_length_max', '50001')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.ai_prompt_purchase_candidates_max', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.ai_prompt_purchase_candidates_max', '51')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.receipt_adjustments_per_receipt', '-1')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.receipt_adjustments_per_receipt', '201')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.receipt_payments_per_receipt', '-1')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.receipt_payments_per_receipt', '101')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.receipt_tax_details_per_receipt', '-1')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.receipt_tax_details_per_receipt', '101')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.receipt_total_amount_max', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.receipt_total_amount_max', '1000000000000')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.receipt_item_price_max', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.receipt_item_price_max', '1000000000000')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.receipt_item_line_total_max', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.receipt_item_line_total_max', '1000000000000')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.receipt_tax_amount_max', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.receipt_tax_amount_max', '1000000000000')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.receipt_adjustment_amount_max', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.receipt_adjustment_amount_max', '1000000000000')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.receipt_payment_amount_max', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.receipt_payment_amount_max', '1000000000000')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.notifications_per_user', '19')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.notifications_per_user', '501')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.batch_upload_max_files', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.batch_upload_max_files', '21')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('retention.notifications_read_days', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('retention.notifications_read_days', '366')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('retention.guest_users_days', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('retention.guest_users_days', '91')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('retention.user_sessions_days', '29')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('retention.user_sessions_days', '366')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('retention.contact_requests_days', '29')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('retention.contact_requests_days', '731')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('retention.analysis_runs_short_days', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('retention.analysis_runs_short_days', '366')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('retention.analysis_runs_default_days', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('retention.analysis_runs_default_days', '366')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('retention.analysis_runs_failed_days', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('retention.analysis_runs_failed_days', '366')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('retention.orphan_blobs_hours', '23')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('retention.orphan_blobs_hours', '721')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('retention.receipt_images_days', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('retention.receipt_images_days', '366')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.max_uploads_per_day', '49')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.max_uploads_per_day', '10001')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.max_ocr_per_day', '49')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.max_ocr_per_day', '10001')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.max_ai_per_day', '49')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.max_ai_per_day', '10001')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.max_storage_bytes', (1.gigabyte - 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.max_storage_bytes', (1.terabyte + 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('security.admin_passkey_reauth_window_minutes', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('security.admin_passkey_reauth_window_minutes', '61')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.guest_storage_bytes', (2.gigabytes).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.receipt_image_max_file_size_bytes', (1.megabyte - 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.receipt_image_max_file_size_bytes', (50.megabytes + 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.announcement_image_max_file_size_bytes', (100.kilobytes - 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.announcement_image_max_file_size_bytes', (10.megabytes + 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.avatar_image_max_file_size_bytes', (100.kilobytes - 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.avatar_image_max_file_size_bytes', (20.megabytes + 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.public_announcements_per_page', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.public_announcements_per_page', '51')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('limits.contact_request_url_count', '-1')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.contact_request_url_count', '21')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('storage.usage_warning_percentage', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('storage.usage_warning_percentage', '100')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('storage.usage_error_percentage', '1')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('storage.usage_error_percentage', '101')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('storage.warning_remaining_bytes', (1.megabyte - 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('storage.warning_remaining_bytes', (20.gigabytes + 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('storage.error_remaining_bytes', (1.megabyte - 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('storage.error_remaining_bytes', (10.gigabytes + 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('storage.remaining_warning_limit_bytes', (10.megabytes - 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('storage.remaining_warning_limit_bytes', (100.gigabytes + 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('storage.global_hard_stop_bytes', (1.gigabyte - 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('storage.global_hard_stop_bytes', (20.terabytes + 1).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('storage.global_usage_warning_percentage', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('storage.global_usage_warning_percentage', '100')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('storage.global_usage_critical_percentage', '1')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('storage.global_usage_critical_percentage', '101')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('security_events.max_detections_per_request', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('security_events.max_detections_per_request', '51')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('security_events.aggregation_window_minutes', '4')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('security_events.aggregation_window_minutes', '1441')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('security_events.admin_burst_window_minutes', '4')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('security_events.admin_burst_window_minutes', '1441')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('security_events.admin_burst_threshold', '1')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('security_events.admin_burst_threshold', '101')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('external_services.failure_window_minutes', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('external_services.failure_window_minutes', '61')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('external_services.degraded_failure_threshold', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('external_services.degraded_failure_threshold', '21')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('external_services.down_failure_threshold', '1')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('external_services.down_failure_threshold', '51')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('external_services.recovery_success_threshold', '0')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('external_services.recovery_success_threshold', '21')
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
      end
    end

    it 'receipt_items_per_receiptはsnapshot OCR/AI上限以下だけ許可する' do
      error_message = 'receipt_items_snapshot_limit'

      aggregate_failures do
        expect(described_class.definition_for('limits.receipt_items_per_receipt').max).to eq(10_000)
        expect(described_class.cast_update_value('limits.receipt_items_per_receipt', '1000')).to eq(1000)
        expect {
          described_class.cast_update_value('limits.receipt_items_per_receipt', '1200')
        }.to raise_error(SystemSettings::ValidationError, error_message)
      end

      create(:system_setting, key: 'limits.snapshot_ocr_items_max', value: SystemSettings.stored_value(1500))

      expect {
        described_class.cast_update_value('limits.receipt_items_per_receipt', '1200')
      }.to raise_error(SystemSettings::ValidationError, error_message)

      create(:system_setting, key: 'limits.snapshot_ai_normalized_items_max', value: SystemSettings.stored_value(1500))

      expect(described_class.cast_update_value('limits.receipt_items_per_receipt', '1200')).to eq(1200)
    end

    it '金額上限は関連する上限との大小関係を維持する' do
      error_message = 'amount_limit_relationship'

      aggregate_failures do
        expect(described_class.cast_update_value('limits.receipt_total_amount_max', '999999999')).to eq(999_999_999)
        expect(described_class.cast_update_value('limits.receipt_item_line_total_max', '999999999')).to eq(999_999_999)
        expect {
          described_class.cast_update_value('limits.receipt_total_amount_max', '999999998')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect {
          described_class.cast_update_value('limits.receipt_payment_amount_max', '1000000000')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect {
          described_class.cast_update_value('limits.receipt_item_line_total_max', '999999998')
        }.to raise_error(SystemSettings::ValidationError, error_message)
      end

      %w[
        limits.receipt_total_amount_max
        limits.receipt_item_line_total_max
        limits.receipt_adjustment_amount_max
        limits.receipt_payment_amount_max
        limits.receipt_tax_amount_max
        limits.receipt_item_price_max
      ].each do |key|
        create(:system_setting, key: key, value: described_class.stored_value(2_000_000_000))
      end

      aggregate_failures do
        expect(described_class.cast_update_value('limits.receipt_total_amount_max', '2000000000')).to eq(2_000_000_000)
        expect(described_class.cast_update_value('limits.receipt_payment_amount_max', '1500000000')).to eq(1_500_000_000)
        expect {
          described_class.cast_update_value('limits.receipt_payment_amount_max', '2500000000')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect {
          described_class.cast_update_value('limits.receipt_item_line_total_max', '1500000000')
        }.to raise_error(SystemSettings::ValidationError, error_message)
      end
    end

    it '画像寸法上限は最小寸法以上だけ許可する' do
      error_message = 'image_dimension_relationship'

      aggregate_failures do
        expect(described_class.cast_update_value('limits.receipt_image_min_dimension_px', '5000')).to eq(5000)
        expect(described_class.cast_update_value('limits.announcement_image_min_dimension_px', '4096')).to eq(4096)
      end

      create(:system_setting, key: 'limits.receipt_image_max_dimension_px', value: described_class.stored_value(2000))
      create(:system_setting, key: 'limits.announcement_image_max_dimension_px', value: described_class.stored_value(2000))

      aggregate_failures do
        expect(described_class.cast_update_value('limits.receipt_image_min_dimension_px', '1500')).to eq(1500)
        expect {
          described_class.cast_update_value('limits.receipt_image_min_dimension_px', '2001')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('limits.announcement_image_min_dimension_px', '1500')).to eq(1500)
        expect {
          described_class.cast_update_value('limits.announcement_image_min_dimension_px', '2001')
        }.to raise_error(SystemSettings::ValidationError, error_message)
      end
    end

    it 'ストレージ警告閾値はwarningとerrorの大小関係を維持する' do
      error_message = 'storage_warning_threshold_relationship'

      aggregate_failures do
        expect(described_class.cast_update_value('storage.usage_warning_percentage', '94')).to eq(94)
        expect {
          described_class.cast_update_value('storage.usage_warning_percentage', '95')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('storage.usage_error_percentage', '81')).to eq(81)
        expect {
          described_class.cast_update_value('storage.usage_error_percentage', '80')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('storage.warning_remaining_bytes', 51.megabytes.to_s)).to eq(51.megabytes)
        expect {
          described_class.cast_update_value('storage.warning_remaining_bytes', 50.megabytes.to_s)
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('storage.error_remaining_bytes', 199.megabytes.to_s)).to eq(199.megabytes)
        expect {
          described_class.cast_update_value('storage.error_remaining_bytes', 200.megabytes.to_s)
        }.to raise_error(SystemSettings::ValidationError, error_message)
      end

      create(:system_setting, key: 'storage.usage_warning_percentage', value: described_class.stored_value(60))
      create(:system_setting, key: 'storage.usage_error_percentage', value: described_class.stored_value(90))
      create(:system_setting, key: 'storage.warning_remaining_bytes', value: described_class.stored_value(500.megabytes))
      create(:system_setting, key: 'storage.error_remaining_bytes', value: described_class.stored_value(100.megabytes))

      aggregate_failures do
        expect(described_class.cast_update_value('storage.usage_warning_percentage', '89')).to eq(89)
        expect {
          described_class.cast_update_value('storage.usage_warning_percentage', '90')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('storage.usage_error_percentage', '61')).to eq(61)
        expect {
          described_class.cast_update_value('storage.usage_error_percentage', '60')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('storage.warning_remaining_bytes', 101.megabytes.to_s)).to eq(101.megabytes)
        expect {
          described_class.cast_update_value('storage.warning_remaining_bytes', 100.megabytes.to_s)
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('storage.error_remaining_bytes', 499.megabytes.to_s)).to eq(499.megabytes)
        expect {
          described_class.cast_update_value('storage.error_remaining_bytes', 500.megabytes.to_s)
        }.to raise_error(SystemSettings::ValidationError, error_message)
      end

      aggregate_failures do
        expect(described_class.cast_update_value('storage.global_usage_warning_percentage', '89')).to eq(89)
        expect {
          described_class.cast_update_value('storage.global_usage_warning_percentage', '90')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('storage.global_usage_critical_percentage', '76')).to eq(76)
        expect {
          described_class.cast_update_value('storage.global_usage_critical_percentage', '75')
        }.to raise_error(SystemSettings::ValidationError, error_message)
      end

      create(
        :system_setting,
        key: 'storage.global_usage_warning_percentage',
        value: described_class.stored_value(60)
      )
      create(
        :system_setting,
        key: 'storage.global_usage_critical_percentage',
        value: described_class.stored_value(90)
      )

      aggregate_failures do
        expect(described_class.cast_update_value('storage.global_usage_warning_percentage', '89')).to eq(89)
        expect {
          described_class.cast_update_value('storage.global_usage_warning_percentage', '90')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('storage.global_usage_critical_percentage', '61')).to eq(61)
        expect {
          described_class.cast_update_value('storage.global_usage_critical_percentage', '60')
        }.to raise_error(SystemSettings::ValidationError, error_message)
      end
    end

    it 'SecurityEvent保持期間は severity 順の大小関係を維持する' do
      error_message = 'security_event_retention_order'

      aggregate_failures do
        expect(described_class.cast_update_value('retention.security_events_critical_days', '180')).to eq(180)
        expect {
          described_class.cast_update_value('retention.security_events_high_days', '181')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('retention.security_events_medium_days', '90')).to eq(90)
        expect {
          described_class.cast_update_value('retention.security_events_medium_days', '181')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('retention.security_events_low_days', '30')).to eq(30)
        expect {
          described_class.cast_update_value('retention.security_events_low_days', '91')
        }.to raise_error(SystemSettings::ValidationError, error_message)
      end

      create(:system_setting, key: 'retention.security_events_critical_days', value: described_class.stored_value(365))
      create(:system_setting, key: 'retention.security_events_high_days', value: described_class.stored_value(180))
      create(:system_setting, key: 'retention.security_events_medium_days', value: described_class.stored_value(90))
      create(:system_setting, key: 'retention.security_events_low_days', value: described_class.stored_value(30))

      aggregate_failures do
        expect(described_class.cast_update_value('retention.security_events_high_days', '365')).to eq(365)
        expect {
          described_class.cast_update_value('retention.security_events_high_days', '366')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('retention.security_events_medium_days', '180')).to eq(180)
        expect {
          described_class.cast_update_value('retention.security_events_medium_days', '181')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('retention.security_events_low_days', '90')).to eq(90)
        expect {
          described_class.cast_update_value('retention.security_events_low_days', '91')
        }.to raise_error(SystemSettings::ValidationError, error_message)
      end
    end

    it '外部サービス状態閾値はdegradedよりdownを大きくする' do
      error_message = 'external_service_status_threshold_relationship'

      aggregate_failures do
        expect(described_class.cast_update_value('external_services.degraded_failure_threshold', '2')).to eq(2)
        expect(described_class.cast_update_value('external_services.down_failure_threshold', '3')).to eq(3)
        expect {
          described_class.cast_update_value('external_services.degraded_failure_threshold', '3')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect {
          described_class.cast_update_value('external_services.down_failure_threshold', '2')
        }.to raise_error(SystemSettings::ValidationError, error_message)
      end

      create(:system_setting, key: 'external_services.down_failure_threshold', value: described_class.stored_value(6))
      create(:system_setting, key: 'external_services.degraded_failure_threshold', value: described_class.stored_value(4))

      aggregate_failures do
        expect(described_class.cast_update_value('external_services.degraded_failure_threshold', '5')).to eq(5)
        expect {
          described_class.cast_update_value('external_services.degraded_failure_threshold', '6')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('external_services.down_failure_threshold', '5')).to eq(5)
        expect {
          described_class.cast_update_value('external_services.down_failure_threshold', '4')
        }.to raise_error(SystemSettings::ValidationError, error_message)
      end
    end

    it '解析run保持期間は failed >= default >= short の関係だけ許可する' do
      error_message = 'analysis_run_retention_order'

      aggregate_failures do
        expect(described_class.cast_update_value('retention.analysis_runs_short_days', '30')).to eq(30)
        expect {
          described_class.cast_update_value('retention.analysis_runs_short_days', '31')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('retention.analysis_runs_default_days', '14')).to eq(14)
        expect {
          described_class.cast_update_value('retention.analysis_runs_default_days', '91')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('retention.analysis_runs_failed_days', '30')).to eq(30)
        expect {
          described_class.cast_update_value('retention.analysis_runs_failed_days', '29')
        }.to raise_error(SystemSettings::ValidationError, error_message)
      end

      create(:system_setting, key: 'retention.analysis_runs_short_days', value: described_class.stored_value(20))
      create(:system_setting, key: 'retention.analysis_runs_default_days', value: described_class.stored_value(40))
      create(:system_setting, key: 'retention.analysis_runs_failed_days', value: described_class.stored_value(80))

      aggregate_failures do
        expect(described_class.cast_update_value('retention.analysis_runs_short_days', '40')).to eq(40)
        expect(described_class.cast_update_value('retention.analysis_runs_default_days', '80')).to eq(80)
        expect(described_class.cast_update_value('retention.analysis_runs_failed_days', '40')).to eq(40)
        expect {
          described_class.cast_update_value('retention.analysis_runs_short_days', '41')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect {
          described_class.cast_update_value('retention.analysis_runs_default_days', '81')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect {
          described_class.cast_update_value('retention.analysis_runs_failed_days', '39')
        }.to raise_error(SystemSettings::ValidationError, error_message)
      end
    end

    it 'upload / OCR / AI / storage系UserLimit設定はシステム上限以下だけ許可する' do
      error_message = 'user_limit_safety_max'
      create(:system_setting, key: 'limits.max_uploads_per_day', value: described_class.stored_value(100))
      create(:system_setting, key: 'limits.max_ocr_per_day', value: described_class.stored_value(100))
      create(:system_setting, key: 'limits.max_ai_per_day', value: described_class.stored_value(200))
      create(:system_setting, key: 'limits.max_storage_bytes', value: described_class.stored_value(1.gigabyte))

      aggregate_failures do
        expect(described_class.cast_update_value('limits.receipt_uploads_per_day', '100')).to eq(100)
        expect(described_class.cast_update_value('limits.batch_files_per_day', '100')).to eq(100)
        expect(described_class.cast_update_value('limits.ocr_jobs_per_day', '100')).to eq(100)
        expect(described_class.cast_update_value('limits.ai_jobs_per_day', '150')).to eq(150)
        expect(described_class.cast_update_value('limits.guest_ocr_jobs_per_day', '50')).to eq(50)
        expect(described_class.cast_update_value('limits.guest_storage_bytes', 1.gigabyte.to_s)).to eq(1.gigabyte)
        expect {
          described_class.cast_update_value('limits.receipt_uploads_per_day', '101')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect {
          described_class.cast_update_value('limits.batch_files_per_day', '101')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect {
          described_class.cast_update_value('limits.ocr_jobs_per_day', '101')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect {
          described_class.cast_update_value('limits.ai_jobs_per_day', '201')
        }.to raise_error(SystemSettings::ValidationError, error_message)
      end

      SystemSetting.find_by!(key: 'limits.max_ocr_per_day').update!(value: described_class.stored_value(50))

      aggregate_failures do
        expect(described_class.cast_update_value('limits.guest_ocr_jobs_per_day', '50')).to eq(50)
        expect {
          described_class.cast_update_value('limits.guest_ocr_jobs_per_day', '51')
        }.to raise_error(SystemSettings::ValidationError, error_message)
      end
    end

    it 'システム上限は関連する既存設定やactive overrideを下回れない' do
      error_message = 'user_limit_safety_max'
      user = create(:user)
      create(:system_setting, key: 'limits.ocr_jobs_per_day', value: described_class.stored_value(150))
      create(:user_limit_override, user: user, key: 'ai_jobs_per_day', value: { 'value' => 150 })
      create(:user_limit_override, user: user, key: 'storage_bytes', value: { 'value' => 2.gigabytes })

      aggregate_failures do
        expect {
          described_class.cast_update_value('limits.max_ocr_per_day', '100')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('limits.max_ocr_per_day', '200')).to eq(200)
        expect {
          described_class.cast_update_value('limits.max_ai_per_day', '100')
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('limits.max_ai_per_day', '200')).to eq(200)
        expect {
          described_class.cast_update_value('limits.max_storage_bytes', 1.gigabyte.to_s)
        }.to raise_error(SystemSettings::ValidationError, error_message)
        expect(described_class.cast_update_value('limits.max_storage_bytes', 3.gigabytes.to_s)).to eq(3.gigabytes)
      end
    end

    it 'snapshot件数上限はhigh risk設定として扱う' do
      aggregate_failures do
        expect(described_class.definition_for('limits.snapshot_ocr_items_max')).to have_attributes(
          category: 'snapshot_limit',
          risk_level: 'high',
          min: 100,
          max: 10_000
        )
        expect(described_class.definition_for('limits.snapshot_ai_normalized_items_max')).to have_attributes(
          category: 'snapshot_limit',
          risk_level: 'high',
          min: 100,
          max: 10_000
        )
      end
    end

    it '調整行件数上限はmedium risk設定として扱う' do
      expect(described_class.definition_for('limits.receipt_adjustments_per_receipt')).to have_attributes(
        category: 'usage_limit',
        risk_level: 'medium',
        min: 0,
        max: 200,
        default: 50
      )
    end

    it '支払い情報件数上限はmedium risk設定として扱う' do
      expect(described_class.definition_for('limits.receipt_payments_per_receipt')).to have_attributes(
        category: 'usage_limit',
        risk_level: 'medium',
        min: 0,
        max: 100,
        default: 20
      )
    end

    it '税区分件数上限はmedium risk設定として扱う' do
      expect(described_class.definition_for('limits.receipt_tax_details_per_receipt')).to have_attributes(
        category: 'usage_limit',
        risk_level: 'medium',
        min: 0,
        max: 100,
        default: 20
      )
    end

    it '金額上限はhigh risk設定として扱う' do
      SystemSettings::AMOUNT_LIMIT_KEYS.each do |key|
        expect(described_class.definition_for(key)).to have_attributes(
          category: 'amount_limit',
          risk_level: 'high',
          min: 1,
          max: 999_999_999_999,
          default: 999_999_999
        )
      end
    end

    it '通知保持件数上限はmedium risk設定として扱う' do
      expect(described_class.definition_for('limits.notifications_per_user')).to have_attributes(
        category: 'usage_limit',
        risk_level: 'medium',
        min: 20,
        max: 500,
        default: 100
      )
    end

    it '一括アップロード件数上限はmedium risk設定として扱う' do
      expect(described_class.definition_for('limits.batch_upload_max_files')).to have_attributes(
        category: 'usage_limit',
        risk_level: 'medium',
        min: 1,
        max: 20,
        default: 5
      )
    end

    it '公開お知らせ一覧の表示件数はlow risk設定として扱う' do
      expect(described_class.definition_for('limits.public_announcements_per_page')).to have_attributes(
        category: 'usage_limit',
        risk_level: 'low',
        min: 1,
        max: 50,
        default: 10
      )
    end

    it '問い合わせURL上限はmedium risk設定として扱う' do
      expect(described_class.definition_for('limits.contact_request_url_count')).to have_attributes(
        category: 'usage_limit',
        risk_level: 'medium',
        min: 0,
        max: 20,
        default: 5
      )
    end

    it '画像アップロード制限は無制限不可の設定として扱う' do
      aggregate_failures do
        expect(described_class.definition_for('limits.receipt_image_max_file_size_bytes')).to have_attributes(
          category: 'upload_limit',
          risk_level: 'high',
          min: 1.megabyte,
          max: 50.megabytes,
          default: 20.megabytes
        )
        expect(described_class.definition_for('limits.receipt_image_min_dimension_px')).to have_attributes(
          category: 'upload_limit',
          risk_level: 'medium',
          min: 1,
          max: 5000,
          default: 100
        )
        expect(described_class.definition_for('limits.receipt_image_max_dimension_px')).to have_attributes(
          category: 'upload_limit',
          risk_level: 'high',
          min: 1000,
          max: 20_000,
          default: 10_000
        )
        expect(described_class.definition_for('limits.announcement_image_max_file_size_bytes')).to have_attributes(
          category: 'upload_limit',
          risk_level: 'high',
          min: 100.kilobytes,
          max: 10.megabytes,
          default: 2.megabytes
        )
        expect(described_class.definition_for('limits.announcement_image_min_dimension_px')).to have_attributes(
          category: 'upload_limit',
          risk_level: 'medium',
          min: 1,
          max: 4096,
          default: 100
        )
        expect(described_class.definition_for('limits.announcement_image_max_dimension_px')).to have_attributes(
          category: 'upload_limit',
          risk_level: 'high',
          min: 1000,
          max: 10_000,
          default: 4096
        )
        expect(described_class.definition_for('limits.avatar_image_max_file_size_bytes')).to have_attributes(
          category: 'upload_limit',
          risk_level: 'high',
          min: 100.kilobytes,
          max: 20.megabytes,
          default: 5.megabytes
        )
      end
    end

    it '既読通知保持期間はmedium risk設定として扱う' do
      expect(described_class.definition_for('retention.notifications_read_days')).to have_attributes(
        category: 'retention',
        risk_level: 'medium',
        min: 1,
        max: 365,
        default: 30
      )
    end

    it 'ゲスト保持期間はmedium risk設定として扱う' do
      expect(described_class.definition_for('retention.guest_users_days')).to have_attributes(
        category: 'retention',
        risk_level: 'medium',
        min: 1,
        max: 90,
        default: 7
      )
    end

    it 'セッション保持期間はmedium risk設定として扱う' do
      expect(described_class.definition_for('retention.user_sessions_days')).to have_attributes(
        category: 'retention',
        risk_level: 'medium',
        min: 30,
        max: 365,
        default: 90
      )
    end

    it '問い合わせ保持期間はmedium risk設定として扱う' do
      expect(described_class.definition_for('retention.contact_requests_days')).to have_attributes(
        category: 'retention',
        risk_level: 'medium',
        min: 30,
        max: 730,
        default: 180
      )
    end

    it '解析run保持期間はmedium risk設定として扱う' do
      aggregate_failures do
        expect(described_class.definition_for('retention.analysis_runs_short_days')).to have_attributes(
          category: 'retention',
          risk_level: 'medium',
          min: 1,
          max: 365,
          default: 14
        )
        expect(described_class.definition_for('retention.analysis_runs_default_days')).to have_attributes(
          category: 'retention',
          risk_level: 'medium',
          min: 1,
          max: 365,
          default: 30
        )
        expect(described_class.definition_for('retention.analysis_runs_failed_days')).to have_attributes(
          category: 'retention',
          risk_level: 'medium',
          min: 1,
          max: 365,
          default: 90
        )
      end
    end

    it 'orphan blob保持期間はhigh risk設定として扱う' do
      expect(described_class.definition_for('retention.orphan_blobs_hours')).to have_attributes(
        category: 'retention',
        risk_level: 'high',
        min: 24,
        max: 720,
        default: 48
      )
    end

    it 'レシート画像保持期間はhigh risk設定として扱う' do
      expect(described_class.definition_for('retention.receipt_images_days')).to have_attributes(
        category: 'retention',
        risk_level: 'high',
        min: 1,
        max: 365,
        default: 1
      )
    end

    it '利用上限のシステム上限はhigh risk設定として扱う' do
      aggregate_failures do
        expect(described_class.definition_for('limits.max_uploads_per_day')).to have_attributes(
          category: 'usage_limit_safety',
          risk_level: 'high',
          min: 50,
          max: 10_000,
          default: 1000
        )
        expect(described_class.definition_for('limits.max_ocr_per_day')).to have_attributes(
          category: 'usage_limit_safety',
          risk_level: 'high',
          min: 50,
          max: 10_000,
          default: 1000
        )
        expect(described_class.definition_for('limits.max_ai_per_day')).to have_attributes(
          category: 'usage_limit_safety',
          risk_level: 'high',
          min: 50,
          max: 10_000,
          default: 1000
        )
        expect(described_class.definition_for('limits.max_storage_bytes')).to have_attributes(
          category: 'usage_limit_safety',
          risk_level: 'high',
          min: 1.gigabyte,
          max: 1.terabyte,
          default: 100.gigabytes
        )
      end
    end

    it 'OCR/AI snapshot上限は運用設定として扱う' do
      aggregate_failures do
        expect(described_class.definition_for('limits.snapshot_ocr_lines_max')).to have_attributes(
          category: 'snapshot_limit',
          risk_level: 'high',
          min: 10,
          max: 1000,
          default: 150
        )
        expect(described_class.definition_for('limits.snapshot_ai_input_filtered_content_max_bytes')).to have_attributes(
          category: 'snapshot_limit',
          risk_level: 'high',
          min: 1.kilobyte,
          max: 100.kilobytes,
          default: 8.kilobytes
        )
        expect(described_class.definition_for('limits.snapshot_string_max_bytes')).to have_attributes(
          category: 'snapshot_limit',
          risk_level: 'high',
          min: 100,
          max: 5000,
          default: 500
        )
        expect(described_class.definition_for('limits.snapshot_store_candidates_max')).to have_attributes(
          category: 'snapshot_limit',
          risk_level: 'medium',
          min: 1,
          max: 100,
          default: 10
        )
        expect(described_class.definition_for('limits.snapshot_review_reasons_max')).to have_attributes(
          category: 'snapshot_limit',
          risk_level: 'medium',
          min: 1,
          max: 100,
          default: 20
        )
      end
    end

    it 'AI prompt上限は運用設定として扱う' do
      aggregate_failures do
        expect(described_class.definition_for('limits.ai_prompt_filtered_content_lines_max')).to have_attributes(
          category: 'ai_prompt_limit',
          risk_level: 'high',
          min: 5,
          max: 500,
          default: 40
        )
        expect(described_class.definition_for('limits.ai_prompt_full_context_lines_max')).to have_attributes(
          category: 'ai_prompt_limit',
          risk_level: 'high',
          min: 10,
          max: 1000,
          default: 150
        )
        expect(described_class.definition_for('limits.ai_prompt_raw_text_length_max')).to have_attributes(
          category: 'ai_prompt_limit',
          risk_level: 'high',
          min: 500,
          max: 50_000,
          default: 4000
        )
        expect(described_class.definition_for('limits.ai_prompt_purchase_candidates_max')).to have_attributes(
          category: 'ai_prompt_limit',
          risk_level: 'medium',
          min: 1,
          max: 50,
          default: 5
        )
      end
    end

    it '管理者再認証期間はhigh risk設定として扱う' do
      expect(described_class.definition_for('security.admin_passkey_reauth_window_minutes')).to have_attributes(
        category: 'security',
        risk_level: 'high',
        min: 1,
        max: 60,
        default: 5
      )
    end

    it 'SecurityEvent運用閾値は設定として扱う' do
      aggregate_failures do
        expect(described_class.definition_for('security_events.max_detections_per_request')).to have_attributes(
          category: 'security_event',
          risk_level: 'high',
          min: 1,
          max: 50,
          default: 5
        )
        expect(described_class.definition_for('security_events.aggregation_window_minutes')).to have_attributes(
          category: 'security_event',
          risk_level: 'medium',
          min: 5,
          max: 1440,
          default: 60
        )
        expect(described_class.definition_for('security_events.admin_burst_window_minutes')).to have_attributes(
          category: 'security_event',
          risk_level: 'high',
          min: 5,
          max: 1440,
          default: 60
        )
        expect(described_class.definition_for('security_events.admin_burst_threshold')).to have_attributes(
          category: 'security_event',
          risk_level: 'high',
          min: 2,
          max: 100,
          default: 5
        )
      end
    end

    it '外部サービス状態閾値はhigh risk設定として扱う' do
      aggregate_failures do
        expect(described_class.definition_for('external_services.failure_window_minutes')).to have_attributes(
          category: 'external_service_status',
          risk_level: 'high',
          min: 1,
          max: 60,
          default: 5
        )
        expect(described_class.definition_for('external_services.degraded_failure_threshold')).to have_attributes(
          category: 'external_service_status',
          risk_level: 'high',
          min: 1,
          max: 20,
          default: 2
        )
        expect(described_class.definition_for('external_services.down_failure_threshold')).to have_attributes(
          category: 'external_service_status',
          risk_level: 'high',
          min: 2,
          max: 50,
          default: 3
        )
        expect(described_class.definition_for('external_services.recovery_success_threshold')).to have_attributes(
          category: 'external_service_status',
          risk_level: 'high',
          min: 1,
          max: 20,
          default: 2
        )
      end
    end

    it 'ストレージ警告閾値と全体上限はrisk設定として扱う' do
      aggregate_failures do
        expect(described_class.definition_for('storage.usage_warning_percentage')).to have_attributes(
          category: 'storage_warning',
          risk_level: 'medium',
          min: 1,
          max: 99,
          default: 80
        )
        expect(described_class.definition_for('storage.usage_error_percentage')).to have_attributes(
          category: 'storage_warning',
          risk_level: 'medium',
          min: 2,
          max: 100,
          default: 95
        )
        expect(described_class.definition_for('storage.warning_remaining_bytes')).to have_attributes(
          category: 'storage_warning',
          risk_level: 'medium',
          min: 1.megabyte,
          max: 20.gigabytes,
          default: 200.megabytes
        )
        expect(described_class.definition_for('storage.error_remaining_bytes')).to have_attributes(
          category: 'storage_warning',
          risk_level: 'medium',
          min: 1.megabyte,
          max: 10.gigabytes,
          default: 50.megabytes
        )
        expect(described_class.definition_for('storage.remaining_warning_limit_bytes')).to have_attributes(
          category: 'storage_warning',
          risk_level: 'medium',
          min: 10.megabytes,
          max: 100.gigabytes,
          default: 1.gigabyte
        )
        expect(described_class.definition_for('storage.global_hard_stop_bytes')).to have_attributes(
          category: 'storage_warning',
          risk_level: 'high',
          min: 1.gigabyte,
          max: 20.terabytes,
          default: 20.gigabytes
        )
        expect(described_class.definition_for('storage.global_usage_warning_percentage')).to have_attributes(
          category: 'storage_warning',
          risk_level: 'medium',
          min: 1,
          max: 99,
          default: 75
        )
        expect(described_class.definition_for('storage.global_usage_critical_percentage')).to have_attributes(
          category: 'storage_warning',
          risk_level: 'high',
          min: 2,
          max: 100,
          default: 90
        )
      end
    end

    it 'SecurityEvent/AuditLog保持期間はhigh risk設定として扱う' do
      aggregate_failures do
        expect(described_class.definition_for('retention.security_events_critical_days')).to have_attributes(
          category: 'retention',
          risk_level: 'high',
          min: 30,
          max: 1095,
          default: 180
        )
        expect(described_class.definition_for('retention.security_events_high_days')).to have_attributes(
          category: 'retention',
          risk_level: 'high',
          min: 30,
          max: 1095,
          default: 180
        )
        expect(described_class.definition_for('retention.security_events_medium_days')).to have_attributes(
          category: 'retention',
          risk_level: 'high',
          min: 30,
          max: 730,
          default: 90
        )
        expect(described_class.definition_for('retention.security_events_low_days')).to have_attributes(
          category: 'retention',
          risk_level: 'high',
          min: 7,
          max: 365,
          default: 30
        )
        expect(described_class.definition_for('retention.audit_logs_high_risk_admin_days')).to have_attributes(
          category: 'retention',
          risk_level: 'high',
          min: 90,
          max: 3650,
          default: 365
        )
        expect(described_class.definition_for('retention.audit_logs_cleanup_execute_days')).to have_attributes(
          category: 'retention',
          risk_level: 'high',
          min: 90,
          max: 3650,
          default: 365
        )
        expect(described_class.definition_for('retention.audit_logs_cleanup_failed_days')).to have_attributes(
          category: 'retention',
          risk_level: 'high',
          min: 30,
          max: 1825,
          default: 180
        )
        expect(described_class.definition_for('retention.audit_logs_passkey_reauth_days')).to have_attributes(
          category: 'retention',
          risk_level: 'high',
          min: 30,
          max: 730,
          default: 90
        )
        expect(described_class.definition_for('retention.audit_logs_system_dry_run_days')).to have_attributes(
          category: 'retention',
          risk_level: 'high',
          min: 7,
          max: 365,
          default: 30
        )
        expect(described_class.definition_for('retention.audit_logs_routine_system_days')).to have_attributes(
          category: 'retention',
          risk_level: 'high',
          min: 30,
          max: 730,
          default: 90
        )
      end
    end

    it '税抜単価の税込補正切り替えはhigh risk設定として扱う' do
      expect(described_class.definition_for('amount_engine.tax_excluded_price_conversion_enabled')).to have_attributes(
        category: 'amount_engine',
        value_type: 'boolean',
        risk_level: 'high',
        default: true
      )
    end

    it 'Amount Engine候補snapshot保存件数はlow risk設定として扱う' do
      expect(described_class.definition_for('amount_engine.max_candidate_snapshot_count')).to have_attributes(
        category: 'amount_engine',
        value_type: 'integer',
        risk_level: 'low',
        min: 1,
        max: 20,
        default: 3
      )
    end

    it 'stringのmaxを検証する' do
      aggregate_failures do
        expect(described_class.cast_update_value('ui.maintenance_notice_title', '臨時メンテナンス')).to eq('臨時メンテナンス')
        expect(described_class.stored_value_for_update('ui.maintenance_notice_title', '臨時メンテナンス')).to eq('value' => '臨時メンテナンス')
        expect(described_class.cast_update_value('maintenance.title', 'メンテナンス中')).to eq('メンテナンス中')
        expect(described_class.cast_update_value('maintenance.body', "1行目\n2行目")).to eq("1行目\n2行目")
        expect {
          described_class.cast_update_value('ui.maintenance_notice_title', 'a' * 81)
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('ui.maintenance_notice_body', 'a' * 1001)
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('maintenance.title', 'a' * 81)
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
        expect {
          described_class.cast_update_value('maintenance.body', 'a' * 1001)
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
      end
    end

    it 'maintenance mode enumをcastする' do
      aggregate_failures do
        expect(described_class.cast_update_value('maintenance.mode', 'login_restricted')).to eq('login_restricted')
        expect(described_class.stored_value_for_update('maintenance.mode', 'off')).to eq('value' => 'off')
        expect {
          described_class.cast_update_value('maintenance.mode', 'full')
        }.to raise_error(SystemSettings::ValidationError, 'invalid_enum')
      end
    end

    it 'percentage / enum / user_allowlist / duration / feature_flagをcastする' do
      with_extra_definitions(
        [
          SystemSettings::Definition.new(
            key: 'feature.rollout_percentage',
            category: 'rollout',
            value_type: 'percentage',
            default: BigDecimal('0'),
            editable: true,
            risk_level: 'medium'
          ),
          SystemSettings::Definition.new(
            key: 'feature.mode',
            category: 'feature_flag',
            value_type: 'enum',
            default: 'off',
            editable: true,
            risk_level: 'low',
            allowed_values: %w[off beta on]
          ),
          SystemSettings::Definition.new(
            key: 'feature.user_allowlist',
            category: 'rollout',
            value_type: 'user_allowlist',
            default: [],
            editable: true,
            risk_level: 'medium'
          ),
          SystemSettings::Definition.new(
            key: 'ui.notice_duration',
            category: 'ui_toggle',
            value_type: 'duration',
            default: 60,
            editable: true,
            risk_level: 'low',
            min: 1,
            max: 3600
          ),
          SystemSettings::Definition.new(
            key: 'feature.test_rollout',
            category: 'feature_flag',
            value_type: 'feature_flag',
            default: { 'enabled' => false, 'rollout_percentage' => 0, 'user_allowlist' => [] },
            editable: true,
            risk_level: 'medium'
          )
        ]
      ) do
        aggregate_failures do
          expect(described_class.cast_update_value('feature.rollout_percentage', '12.5')).to eq(BigDecimal('12.5'))
          expect(described_class.stored_value_for_update('feature.rollout_percentage', '12.5')).to eq('value' => '12.5')
          expect(described_class.cast_update_value('feature.mode', 'beta')).to eq('beta')
          expect {
            described_class.cast_update_value('feature.mode', 'invalid')
          }.to raise_error(SystemSettings::ValidationError, 'invalid_enum')
          expect(described_class.cast_update_value('feature.user_allowlist', "1\n2, 2 3")).to eq(%w[1 2 3])
          expect(described_class.cast_update_value('ui.notice_duration', { value: '5', unit: 'minutes' })).to eq(300)
          expect(described_class.cast_update_value('feature.test_rollout', '{"enabled":true,"rollout_percentage":12.5,"user_allowlist":["1",2]}')).to eq(
            'enabled' => true,
            'rollout_percentage' => BigDecimal('12.5'),
            'user_allowlist' => %w[1 2]
          )
        end
      end
    end
  end

  def with_extra_definitions(extra_definitions)
    original_definitions = described_class.definitions
    merged_definitions = original_definitions.merge(extra_definitions.index_by(&:key))

    allow(described_class).to receive(:definitions).and_return(merged_definitions)
    yield
  ensure
    allow(described_class).to receive(:definitions).and_call_original
  end
end
