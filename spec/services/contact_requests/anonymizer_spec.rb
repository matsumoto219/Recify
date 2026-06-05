require "rails_helper"

RSpec.describe ContactRequests::Anonymizer do
  include ActiveSupport::Testing::TimeHelpers

  describe ".call" do
    it "removes PII and keeps contact request history fields" do
      user = create(:user)
      handler = create(:user, admin: true)
      contact_request = create(
        :contact_request,
        user: user,
        handled_by_user: handler,
        status: "resolved",
        category: "security",
        source: "authenticated",
        sender_name: "問い合わせ 太郎",
        email: "sender@example.com",
        email_digest: ContactRequests.email_digest("sender@example.com"),
        subject: "秘密の件名",
        body: "個人情報を含む本文",
        ip_address: "203.0.113.40",
        user_agent: "RSpec browser",
        request_id: "request-id-1",
        handled_at: 200.days.ago
      )

      described_class.call(contact_request)
      contact_request.reload

      aggregate_failures do
        expect(contact_request.sender_name).to be_nil
        expect(contact_request.email).to eq("redacted+#{contact_request.request_uid}@example.invalid")
        expect(contact_request.subject).to eq("[redacted]")
        expect(contact_request.body).to eq("[redacted by retention policy]")
        expect(contact_request.ip_address).to be_nil
        expect(contact_request.user_agent).to be_nil
        expect(contact_request.request_id).to be_nil

        expect(contact_request.request_uid).to be_present
        expect(contact_request.status).to eq("resolved")
        expect(contact_request.category).to eq("security")
        expect(contact_request.source).to eq("authenticated")
        expect(contact_request.email_digest).to eq(ContactRequests.email_digest("sender@example.com"))
        expect(contact_request.handled_at).to be_present
        expect(contact_request.handled_by_user).to eq(handler)
      end
    end

    it "is idempotent" do
      contact_request = create(:contact_request, status: "closed", handled_at: 200.days.ago)

      described_class.call(contact_request)
      anonymized_attributes = contact_request.reload.attributes.slice(
        "sender_name",
        "email",
        "subject",
        "body",
        "ip_address",
        "user_agent",
        "request_id",
        "updated_at"
      )

      travel 1.minute do
        described_class.call(contact_request)
      end

      expect(contact_request.reload.attributes.slice(*anonymized_attributes.keys)).to eq(anonymized_attributes)
    end
  end

  describe ".anonymized?" do
    it "detects anonymized contact requests" do
      contact_request = create(:contact_request)

      aggregate_failures do
        expect(described_class.anonymized?(contact_request)).to be(false)
        described_class.call(contact_request)
        expect(described_class.anonymized?(contact_request.reload)).to be(true)
      end
    end
  end
end
