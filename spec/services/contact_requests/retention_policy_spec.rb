require "rails_helper"

RSpec.describe ContactRequests::RetentionPolicy do
  describe ".anonymizable_scope" do
    let(:now) { Time.zone.local(2026, 6, 5, 12, 0, 0) }

    it "open and in_progress requests are not anonymizable" do
      open_request = create(:contact_request, status: "open", updated_at: 181.days.before(now))
      in_progress_request = create(:contact_request, status: "in_progress", updated_at: 181.days.before(now))

      expect(described_class.anonymizable_scope(now: now)).not_to include(open_request, in_progress_request)
    end

    it "includes resolved requests handled before the retention cutoff" do
      contact_request = create(
        :contact_request,
        status: "resolved",
        handled_at: 181.days.before(now),
        updated_at: 10.days.before(now)
      )

      expect(described_class.anonymizable_scope(now: now)).to include(contact_request)
    end

    it "includes closed requests handled before the retention cutoff" do
      contact_request = create(
        :contact_request,
        status: "closed",
        handled_at: 181.days.before(now),
        updated_at: 10.days.before(now)
      )

      expect(described_class.anonymizable_scope(now: now)).to include(contact_request)
    end

    it "excludes resolved requests handled after the retention cutoff" do
      contact_request = create(
        :contact_request,
        status: "resolved",
        handled_at: 179.days.before(now),
        updated_at: 181.days.before(now)
      )

      expect(described_class.anonymizable_scope(now: now)).not_to include(contact_request)
    end

    it "falls back to updated_at when handled_at is blank" do
      old_request = create(:contact_request, status: "resolved", handled_at: nil, updated_at: 181.days.before(now))
      recent_request = create(:contact_request, status: "resolved", handled_at: nil, updated_at: 179.days.before(now))

      aggregate_failures do
        expect(described_class.anonymizable_scope(now: now)).to include(old_request)
        expect(described_class.anonymizable_scope(now: now)).not_to include(recent_request)
      end
    end
  end

  describe ".retention_cutoff" do
    it "uses the 180 day contact request retention period" do
      now = Time.zone.local(2026, 6, 5, 12, 0, 0)

      aggregate_failures do
        expect(described_class::CONTACT_REQUEST_RETENTION_DAYS).to eq(180)
        expect(described_class.retention_cutoff(now: now)).to eq(180.days.before(now))
      end
    end
  end
end
