require 'rails_helper'

RSpec.describe SystemSettings do
  describe '.definitions' do
    it 'code-side definition allowlistを返す' do
      expect(described_class.definitions.keys).to contain_exactly(
        'feature.receipt_image_preprocess_enabled',
        'feature.receipt_logo_display_enabled',
        'ui.maintenance_notice_enabled',
        'limits.receipt_upload_soft_limit'
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
end
