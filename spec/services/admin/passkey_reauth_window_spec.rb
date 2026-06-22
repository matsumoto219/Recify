require 'rails_helper'

RSpec.describe Admin::PasskeyReauthWindow do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-06-13 10:00:00')) { example.run }
  end

  describe '.duration' do
    it 'defaultは5分にする' do
      expect(described_class.duration).to eq(5.minutes)
    end

    it 'SystemSettingsの分数を参照する' do
      create(:system_setting, key: 'security.admin_passkey_reauth_window_minutes', value: SystemSettings.stored_value(15))

      expect(described_class.duration).to eq(15.minutes)
    end
  end

  describe '.fresh?' do
    it 'default window内のpasskey再認証をfreshにする' do
      moment = 4.minutes.ago
      context = { method: 'passkey' }
      context[:reauthenticated_at] = moment

      expect(described_class.fresh?(context)).to be(true)
    end

    it 'default windowを超えたpasskey再認証をfreshにしない' do
      moment = 6.minutes.ago
      context = { method: 'passkey' }
      context[:reauthenticated_at] = moment

      expect(described_class.fresh?(context)).to be(false)
    end

    it 'SystemSettingsが1分なら2分前の再認証をfreshにしない' do
      create(:system_setting, key: 'security.admin_passkey_reauth_window_minutes', value: SystemSettings.stored_value(1))
      moment = 2.minutes.ago
      context = { method: 'passkey' }
      context[:reauthenticated_at] = moment

      expect(described_class.fresh?(context)).to be(false)
    end

    it 'SystemSettingsが15分なら10分前の再認証をfreshにする' do
      create(:system_setting, key: 'security.admin_passkey_reauth_window_minutes', value: SystemSettings.stored_value(15))
      moment = 10.minutes.ago
      context = { method: 'passkey' }
      context[:reauthenticated_at] = moment

      expect(described_class.fresh?(context)).to be(true)
    end

    it 'passkey以外のmethodはfreshにしない' do
      context = { method: 'password', reauthenticated_at: Time.current }

      expect(described_class.fresh?(context)).to be(false)
    end
  end
end
