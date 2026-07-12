require "rails_helper"

RSpec.describe Admin::Operations do
  it "routine mutationのpublic APIをexactに限定する" do
    expect(described_class.singleton_methods(false)).to contain_exactly(
      :update_contact_request_status,
      :update_security_event_status
    )
  end

  describe ".update_contact_request_status" do
    it "ContactRequestStatusUpdaterへ委譲する" do
      arguments = {
        contact_request: build_stubbed(:contact_request),
        status: "in_progress",
        actor: build_stubbed(:user, :admin),
        request: instance_double(ActionDispatch::Request)
      }
      result = instance_double(Admin::ContactRequestStatusUpdater::Result)
      allow(Admin::ContactRequestStatusUpdater).to receive(:call).and_return(result)

      expect(described_class.update_contact_request_status(**arguments)).to eq(result)
      expect(Admin::ContactRequestStatusUpdater).to have_received(:call).with(**arguments)
    end
  end

  describe ".update_security_event_status" do
    it "SecurityEventStatusUpdaterへ委譲する" do
      arguments = {
        security_event: build_stubbed(:security_event),
        status: "resolved",
        actor: build_stubbed(:user, :admin),
        request: instance_double(ActionDispatch::Request)
      }
      result = instance_double(Admin::SecurityEventStatusUpdater::Result)
      allow(Admin::SecurityEventStatusUpdater).to receive(:call).and_return(result)

      expect(described_class.update_security_event_status(**arguments)).to eq(result)
      expect(Admin::SecurityEventStatusUpdater).to have_received(:call).with(**arguments)
    end
  end
end
