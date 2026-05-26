require 'rails_helper'

RSpec.describe SystemSetting, type: :model do
  it 'definition allowlistにあるkeyだけ保存できる' do
    setting = build(:system_setting, key: 'feature.receipt_logo_display_enabled')

    expect(setting).to be_valid
  end

  it 'unknown keyを拒否する' do
    setting = build(:system_setting, key: 'secret.provider_api_key')

    expect(setting).not_to be_valid
    expect(setting.errors[:key]).to be_present
  end

  it 'valueはHashだけ許可する' do
    setting = build(:system_setting, value: true)

    expect(setting).not_to be_valid
    expect(setting.errors[:value]).to be_present
  end

  it 'definitionのvalue_typeに合わない値を拒否する' do
    setting = build(
      :system_setting,
      key: 'limits.receipt_upload_soft_limit',
      value: SystemSettings.stored_value(10_000)
    )

    expect(setting).not_to be_valid
    expect(setting.errors[:value]).to be_present
  end

  it 'updated_by_userはoptionalにする' do
    setting = build(:system_setting, updated_by_user: nil)

    expect(setting).to be_valid
  end

  it 'lock_versionでoptimistic lockingを使う' do
    setting = create(:system_setting)

    expect(setting.reload.lock_version).to eq(0)
  end
end
