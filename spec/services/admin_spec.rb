require 'rails_helper'

RSpec.describe Admin do
  describe '.passkey_reauth_fresh?' do
    it '管理者再認証window判定の親入口である' do
      reauthentication = { method: 'passkey', reauthenticated_at: Time.current }

      allow(Admin::PasskeyReauthWindow).to receive(:fresh?).and_return(true)

      expect(described_class.passkey_reauth_fresh?(reauthentication)).to be(true)
      expect(Admin::PasskeyReauthWindow).to have_received(:fresh?).with(reauthentication)
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

  describe '.update_contact_request_status' do
    it 'ContactRequestStatusUpdaterへ委譲する親入口である' do
      contact_request = build_stubbed(:contact_request)
      actor = build_stubbed(:user, :admin)
      request = instance_double(ActionDispatch::Request)
      result = Admin::ContactRequestStatusUpdater::Result.new(contact_request: contact_request, updated: true)

      allow(Admin::ContactRequestStatusUpdater).to receive(:call).and_return(result)

      expect(
        described_class.update_contact_request_status(
          contact_request: contact_request,
          status: 'in_progress',
          actor: actor,
          request: request
        )
      ).to eq(result)

      expect(Admin::ContactRequestStatusUpdater).to have_received(:call).with(
        contact_request: contact_request,
        status: 'in_progress',
        actor: actor,
        request: request
      )
    end
  end
end
