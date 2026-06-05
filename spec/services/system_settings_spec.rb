require 'rails_helper'

RSpec.describe SystemSettings do
  describe '.definitions' do
    it 'code-side definition allowlistを返す' do
      expect(described_class.definitions.keys).to contain_exactly(
        'feature.receipt_image_preprocess_enabled',
        'feature.receipt_logo_display_enabled',
        'feature.receipt_image_preprocess',
        'feature.receipt_logo_display',
        'ui.maintenance_notice_enabled',
        'ui.maintenance_notice_title',
        'ui.maintenance_notice_body',
        'maintenance.mode',
        'maintenance.title',
        'maintenance.body',
        'security.admin_passkey_reauth_window_minutes',
        'storage.keep_receipt_images_default',
        'limits.receipt_upload_soft_limit',
        'limits.receipt_uploads_per_day',
        'limits.manual_receipts_per_day',
        'limits.receipt_items_per_receipt',
        'limits.receipt_adjustments_per_receipt',
        'limits.receipt_payments_per_receipt',
        'limits.receipt_tax_details_per_receipt',
        'limits.notifications_per_user',
        'retention.notifications_read_days',
        'retention.guest_users_days',
        'retention.user_sessions_days',
        'retention.contact_requests_days',
        'retention.analysis_runs_short_days',
        'retention.analysis_runs_default_days',
        'retention.analysis_runs_failed_days',
        'limits.max_uploads_per_day',
        'limits.max_ocr_per_day',
        'limits.max_ai_per_day',
        'limits.max_storage_bytes',
        'limits.snapshot_ocr_items_max',
        'limits.snapshot_ai_normalized_items_max',
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
  end

  describe '.value_for' do
    it 'DB値がない場合はdefaultを返す' do
      expect(described_class.value_for('feature.receipt_logo_display_enabled')).to eq(false)
    end

    it 'レシート画像保持defaultはtrueを返す' do
      expect(described_class.value_for('storage.keep_receipt_images_default')).to eq(true)
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
        expect(described_class.limit_for('limits.notifications_per_user')).to eq(100)
        expect(described_class.limit_for('retention.notifications_read_days')).to eq(30)
        expect(described_class.limit_for('retention.guest_users_days')).to eq(7)
        expect(described_class.limit_for('retention.user_sessions_days')).to eq(90)
        expect(described_class.limit_for('retention.contact_requests_days')).to eq(180)
        expect(described_class.limit_for('retention.analysis_runs_short_days')).to eq(14)
        expect(described_class.limit_for('retention.analysis_runs_default_days')).to eq(30)
        expect(described_class.limit_for('retention.analysis_runs_failed_days')).to eq(90)
        expect(described_class.limit_for('limits.max_uploads_per_day')).to eq(1000)
        expect(described_class.limit_for('limits.max_ocr_per_day')).to eq(1000)
        expect(described_class.limit_for('limits.max_ai_per_day')).to eq(1000)
        expect(described_class.limit_for('limits.max_storage_bytes')).to eq(100.gigabytes)
        expect(described_class.limit_for('limits.snapshot_ocr_items_max')).to eq(1000)
        expect(described_class.limit_for('limits.snapshot_ai_normalized_items_max')).to eq(1000)
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
        expect(described_class.cast_update_value('limits.receipt_adjustments_per_receipt', '0')).to eq(0)
        expect(described_class.cast_update_value('limits.receipt_adjustments_per_receipt', '200')).to eq(200)
        expect(described_class.cast_update_value('limits.receipt_payments_per_receipt', '0')).to eq(0)
        expect(described_class.cast_update_value('limits.receipt_payments_per_receipt', '100')).to eq(100)
        expect(described_class.cast_update_value('limits.receipt_tax_details_per_receipt', '0')).to eq(0)
        expect(described_class.cast_update_value('limits.receipt_tax_details_per_receipt', '100')).to eq(100)
        expect(described_class.cast_update_value('limits.notifications_per_user', '20')).to eq(20)
        expect(described_class.cast_update_value('limits.notifications_per_user', '500')).to eq(500)
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
          described_class.cast_update_value('limits.notifications_per_user', '19')
        }.to raise_error(SystemSettings::ValidationError, 'below_min')
        expect {
          described_class.cast_update_value('limits.notifications_per_user', '501')
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

    it '通知保持件数上限はmedium risk設定として扱う' do
      expect(described_class.definition_for('limits.notifications_per_user')).to have_attributes(
        category: 'usage_limit',
        risk_level: 'medium',
        min: 20,
        max: 500,
        default: 100
      )
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

    it '管理者再認証期間はhigh risk設定として扱う' do
      expect(described_class.definition_for('security.admin_passkey_reauth_window_minutes')).to have_attributes(
        category: 'security',
        risk_level: 'high',
        min: 1,
        max: 60,
        default: 5
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
