require 'rails_helper'

RSpec.describe Maintenance do
  describe '.mode' do
    it 'defaultはoffを返す' do
      expect(described_class.mode).to eq('off')
    end

    it 'SystemSettingsのmaintenance.modeを返す' do
      create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))

      expect(described_class.mode).to eq('login_restricted')
    end
  end

  describe '.login_restricted?' do
    it 'login_restrictedの場合だけtrueを返す' do
      expect(described_class.login_restricted?).to be(false)

      create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))

      expect(described_class.login_restricted?).to be(true)
    end
  end

  describe '.admin_bypass_user?' do
    it 'activeなadminだけtrueを返す' do
      admin = create(:user, :admin)
      user = create(:user)
      guest = create(:user, guest: true)

      aggregate_failures do
        expect(described_class.admin_bypass_user?(admin)).to be(true)
        expect(described_class.admin_bypass_user?(user)).to be(false)
        expect(described_class.admin_bypass_user?(guest)).to be(false)
        expect(described_class.admin_bypass_user?(nil)).to be(false)
      end
    end
  end

  describe '.login_allowed_for?' do
    it 'offなら一般ユーザーも許可する' do
      expect(described_class.login_allowed_for?(create(:user))).to be(true)
    end

    it 'login_restrictedならadminだけ許可する' do
      create(:system_setting, key: 'maintenance.mode', value: SystemSettings.stored_value('login_restricted'))

      aggregate_failures do
        expect(described_class.login_allowed_for?(create(:user, :admin))).to be(true)
        expect(described_class.login_allowed_for?(create(:user))).to be(false)
      end
    end
  end

  describe '.title and .body' do
    it 'blankならlocale fallbackを返す' do
      aggregate_failures do
        expect(described_class.title).to eq(I18n.t('shared.maintenance_mode.title'))
        expect(described_class.body).to eq(I18n.t('shared.maintenance_mode.body'))
      end
    end

    it '設定値があれば設定値を返す' do
      create(:system_setting, key: 'maintenance.title', value: SystemSettings.stored_value('臨時メンテナンス'))
      create(:system_setting, key: 'maintenance.body', value: SystemSettings.stored_value("1行目\n2行目"))

      aggregate_failures do
        expect(described_class.title).to eq('臨時メンテナンス')
        expect(described_class.body).to eq("1行目\n2行目")
      end
    end
  end
end
