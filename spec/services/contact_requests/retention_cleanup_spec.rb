require "rails_helper"

RSpec.describe ContactRequests::RetentionCleanup do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse("2026-06-05 12:00:00")) { example.run }
  end

  describe ".call" do
    it "dry-run returns anonymizable contact requests without changing them" do
      expired = create(:contact_request, status: "resolved", handled_at: 181.days.ago, body: "PII body")
      recent = create(:contact_request, status: "resolved", handled_at: 10.days.ago)
      open_request = create(:contact_request, status: "open", updated_at: 181.days.ago)

      result = described_class.call(dry_run: true, now: Time.current)

      aggregate_failures do
        expect(result).to include(
          dry_run: true,
          cutoff: 180.days.ago,
          retention_days: 180,
          limit: 1000,
          candidate_count: 1,
          anonymized_count: 0,
          failed_count: 0,
          errors: []
        )
        expect(result[:sample_request_uids]).to contain_exactly(expired.request_uid)
        expect(result[:records].map { |record| record[:request_uid] }).to contain_exactly(expired.request_uid)
        expect(expired.reload.body).to eq("PII body")
        expect(ContactRequest.where(id: [ expired.id, recent.id, open_request.id ]).count).to eq(3)
      end
    end

    it "execute anonymizes targets and does not hard delete contact requests" do
      expired = create(
        :contact_request,
        status: "closed",
        handled_at: 181.days.ago,
        sender_name: "送信者",
        email: "sender@example.com",
        subject: "secret subject",
        body: "secret body",
        ip_address: "203.0.113.1",
        user_agent: "Secret Browser",
        request_id: "request-id"
      )
      recent = create(:contact_request, status: "closed", handled_at: 10.days.ago)

      result = described_class.call(dry_run: false, now: Time.current)

      aggregate_failures do
        expect(result[:candidate_count]).to eq(1)
        expect(result[:anonymized_count]).to eq(1)
        expect(result[:failed_count]).to eq(0)
        expect(ContactRequest.where(id: [ expired.id, recent.id ]).count).to eq(2)
        expect(ContactRequests.anonymized?(expired.reload)).to be(true)
        expect(ContactRequests.anonymized?(recent.reload)).to be(false)
      end
    end

    it "does not select already anonymized contact requests again" do
      expired = create(:contact_request, status: "resolved", handled_at: 181.days.ago)

      ContactRequests.anonymize(expired)

      result = described_class.call(dry_run: true, now: Time.current)

      expect(result[:candidate_count]).to eq(0)
    end

    it "applies limit and sample_request_uids limit" do
      contact_requests = create_list(:contact_request, 6, status: "resolved", handled_at: 181.days.ago)

      result = described_class.call(dry_run: true, now: Time.current, limit: 6)

      aggregate_failures do
        expect(result[:candidate_count]).to eq(6)
        expect(result[:sample_request_uids]).to eq(contact_requests.map(&:request_uid).first(5))
      end
    end

    it "uses the configured retention period in result metadata" do
      create(
        :system_setting,
        key: "retention.contact_requests_days",
        value: SystemSettings.stored_value(90)
      )
      expired = create(:contact_request, status: "resolved", handled_at: 91.days.ago)
      create(:contact_request, status: "resolved", handled_at: 89.days.ago)

      result = described_class.call(dry_run: true, now: Time.current)

      aggregate_failures do
        expect(result[:cutoff]).to eq(90.days.ago)
        expect(result[:retention_days]).to eq(90)
        expect(result[:candidate_count]).to eq(1)
        expect(result[:sample_request_uids]).to contain_exactly(expired.request_uid)
      end
    end

    it "does not include PII in the result payload" do
      create(
        :contact_request,
        status: "resolved",
        handled_at: 181.days.ago,
        sender_name: "秘密 太郎",
        email: "secret@example.com",
        subject: "secret subject",
        body: "secret body",
        ip_address: "203.0.113.99",
        user_agent: "Sensitive Browser",
        request_id: "request-secret"
      )

      result_json = described_class.call(dry_run: true, now: Time.current).to_json

      expect(result_json).not_to include(
        "秘密 太郎",
        "secret@example.com",
        "secret subject",
        "secret body",
        "203.0.113.99",
        "Sensitive Browser",
        "request-secret"
      )
    end
  end
end
