require "rails_helper"

RSpec.describe ContactRequestRetentionCleanupJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse("2026-06-05 12:00:00")) { example.run }
  end

  it "dry_run trueをdefaultにしてContactRequests親入口を呼ぶ" do
    result = {
      dry_run: true,
      cutoff: 180.days.ago,
      retention_days: 180,
      limit: 1000,
      candidate_count: 0,
      anonymized_count: 0,
      failed_count: 0,
      sample_request_uids: []
    }
    allow(ContactRequests).to receive(:cleanup_retention).and_return(result)
    allow(Rails.logger).to receive(:info)

    expect { expect(described_class.perform_now).to eq(result) }
      .to change(AuditLog, :count).by(1)

    audit_log = AuditLog.last

    aggregate_failures do
      expect(ContactRequests).to have_received(:cleanup_retention).with(
        dry_run: true,
        now: kind_of(ActiveSupport::TimeWithZone),
        limit: 1000
      )
      expect(Rails.logger).to have_received(:info).with(include("[ContactRequestRetentionCleanupJob] completed dry_run=true"))
      expect(audit_log).to have_attributes(
        actor_kind: "system",
        action: "contact_requests.retention_cleanup.dry_run",
        outcome: "succeeded"
      )
      expect(audit_log.metadata).to include(
        "dry_run" => true,
        "retention_days" => 180,
        "limit" => 1000,
        "candidate_count" => 0,
        "anonymized_count" => 0,
        "failed_count" => 0
      )
      expect(audit_log.metadata).not_to have_key("sample_request_uids")
    end
  end

  it "execute mode uses the execute audit action and keeps PII out of AuditLog" do
    result = {
      dry_run: false,
      cutoff: 180.days.ago,
      retention_days: 180,
      limit: 10,
      candidate_count: 1,
      anonymized_count: 1,
      failed_count: 0,
      sample_request_uids: [ "cr_sample" ],
      email: "secret@example.com",
      body: "secret body",
      user_agent: "Sensitive Browser"
    }
    allow(ContactRequests).to receive(:cleanup_retention).and_return(result)

    described_class.perform_now(dry_run: false, limit: 10)

    audit_log = AuditLog.last
    metadata_json = audit_log.metadata.to_json

    aggregate_failures do
      expect(audit_log).to have_attributes(
        actor_kind: "system",
        action: "contact_requests.retention_cleanup.execute",
        outcome: "succeeded"
      )
      expect(audit_log.metadata).to include(
        "dry_run" => false,
        "limit" => 10,
        "candidate_count" => 1,
        "anonymized_count" => 1,
        "failed_count" => 0
      )
      expect(metadata_json).not_to include("secret@example.com")
      expect(metadata_json).not_to include("secret body")
      expect(metadata_json).not_to include("Sensitive Browser")
      expect(metadata_json).not_to include("cr_sample")
    end
  end

  it "cleanup失敗時にfailed auditを残して例外を再raiseする" do
    error = StandardError.new("boom")
    allow(ContactRequests).to receive(:cleanup_retention).and_raise(error)

    expect do
      described_class.perform_now
    end.to raise_error(StandardError, "boom")
      .and change(AuditLog, :count).by(1)

    audit_log = AuditLog.last

    aggregate_failures do
      expect(audit_log).to have_attributes(
        actor_kind: "system",
        action: "contact_requests.retention_cleanup.dry_run",
        outcome: "failed",
        error_code: "cleanup_failed"
      )
      expect(audit_log.metadata).to include(
        "dry_run" => true,
        "retention_days" => 180,
        "limit" => 1000,
        "error_class" => "StandardError"
      )
      expect(audit_log.metadata).not_to have_key("error_message")
    end
  end
end
