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
        'storage.keep_receipt_images_default',
        'limits.receipt_upload_soft_limit',
        'limits.receipt_uploads_per_day',
        'limits.batch_files_per_day',
        'limits.ocr_jobs_per_day',
        'limits.ai_jobs_per_day',
        'limits.retry_operations_per_day',
        'limits.guest_receipt_uploads_per_day',
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
        expect(described_class.limit_for('limits.batch_files_per_day')).to eq(50)
        expect(described_class.limit_for('limits.ocr_jobs_per_day')).to eq(50)
        expect(described_class.limit_for('limits.ai_jobs_per_day')).to eq(50)
        expect(described_class.limit_for('limits.retry_operations_per_day')).to eq(20)
        expect(described_class.limit_for('limits.guest_receipt_uploads_per_day')).to eq(5)
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
        expect {
          described_class.cast_update_value('limits.guest_storage_bytes', (2.gigabytes).to_s)
        }.to raise_error(SystemSettings::ValidationError, 'above_max')
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
