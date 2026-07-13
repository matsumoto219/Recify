require 'rails_helper'

RSpec.describe Admin do
  describe '.passkey_reauth_fresh?' do
    it '管理者再認証window判定の親入口である' do
      user = build_stubbed(:user, :admin)
      reauthentication = { method: 'passkey', reauthenticated_at: Time.current }

      allow(Admin::PasskeyReauthWindow).to receive(:fresh?).and_return(true)

      expect(described_class.passkey_reauth_fresh?(reauthentication, user: user)).to be(true)
      expect(Admin::PasskeyReauthWindow).to have_received(:fresh?).with(reauthentication, user: user)
    end
  end

  describe '.passkey_reauthenticated_at' do
    it '管理者再認証時刻取得の親入口である' do
      reauthentication = { method: 'passkey', reauthenticated_at: Time.current.iso8601 }
      reauthenticated_at = Time.current

      allow(Admin::PasskeyReauthWindow).to receive(:reauthenticated_at).and_return(reauthenticated_at)

      expect(described_class.passkey_reauthenticated_at(reauthentication)).to eq(reauthenticated_at)
      expect(Admin::PasskeyReauthWindow).to have_received(:reauthenticated_at).with(reauthentication)
    end
  end
end
