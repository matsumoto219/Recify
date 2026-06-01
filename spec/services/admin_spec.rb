require 'rails_helper'

RSpec.describe Admin do
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
