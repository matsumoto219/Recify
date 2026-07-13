require 'rails_helper'

RSpec.describe Admin::PasskeyReauthWindow do
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { create(:user, :admin) }

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
    def context_for(user: admin, reauthenticated_at: Time.current, expires_at: nil, method: 'passkey')
      {
        method: method,
        reauthenticated_at: reauthenticated_at,
        user_id: user.id,
        session_version: user.session_version,
        expires_at: expires_at || (reauthenticated_at + described_class.duration)
      }
    end

    it 'default window内のpasskey再認証をfreshにする' do
      moment = 4.minutes.ago

      expect(described_class.fresh?(context_for(reauthenticated_at: moment), user: admin)).to be(true)
    end

    it 'default windowを超えたpasskey再認証をfreshにしない' do
      moment = 6.minutes.ago

      expect(described_class.fresh?(context_for(reauthenticated_at: moment), user: admin)).to be(false)
    end

    it 'SystemSettingsが1分なら2分前の再認証をfreshにしない' do
      create(:system_setting, key: 'security.admin_passkey_reauth_window_minutes', value: SystemSettings.stored_value(1))
      moment = 2.minutes.ago

      expect(described_class.fresh?(context_for(reauthenticated_at: moment), user: admin)).to be(false)
    end

    it 'SystemSettingsが15分なら10分前の再認証をfreshにする' do
      create(:system_setting, key: 'security.admin_passkey_reauth_window_minutes', value: SystemSettings.stored_value(15))
      moment = 10.minutes.ago

      expect(described_class.fresh?(context_for(reauthenticated_at: moment), user: admin)).to be(true)
    end

    it 'passkey以外のmethodはfreshにしない' do
      context = context_for(method: 'password')

      expect(described_class.fresh?(context, user: admin)).to be(false)
    end

    it '別の管理者へ発行されたcontextをfreshにしない' do
      other_admin = create(:user, :admin)

      expect(described_class.fresh?(context_for, user: other_admin)).to be(false)
    end

    it 'session version変更後はfreshにしない' do
      context = context_for
      admin.update!(session_version: admin.session_version + 1)

      expect(described_class.fresh?(context, user: admin)).to be(false)
    end

    it '発行時期限がない旧contextをfreshにしない' do
      context = context_for.except(:expires_at)

      expect(described_class.fresh?(context, user: admin)).to be(false)
    end

    it 'userまたはsession versionがないcontextをfreshにしない' do
      expect(described_class.fresh?(context_for.except(:user_id), user: admin)).to be(false)
      expect(described_class.fresh?(context_for.except(:session_version), user: admin)).to be(false)
    end

    it '未来の再認証時刻をfreshにしない' do
      context = context_for(reauthenticated_at: 1.minute.from_now)

      expect(described_class.fresh?(context, user: admin)).to be(false)
    end

    it '不正な発行時期限をfreshにしない' do
      context = context_for.merge(expires_at: 'invalid-time')

      expect(described_class.fresh?(context, user: admin)).to be(false)
    end

    it '設定を延長しても発行時期限を超えてfreshにしない' do
      setting = create(
        :system_setting,
        key: 'security.admin_passkey_reauth_window_minutes',
        value: SystemSettings.stored_value(1)
      )
      context = context_for
      setting.update!(value: SystemSettings.stored_value(15))

      travel 2.minutes

      expect(described_class.fresh?(context, user: admin)).to be(false)
    end
  end
end
