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

  it "partial failureはexecute auditをfailedとして記録する" do
    allow(ContactRequests).to receive(:cleanup_retention).and_return(
      dry_run: false,
      candidate_count: 2,
      anonymized_count: 1,
      skipped_count: 0,
      failed_count: 1,
      errors: [ { request_uid: "cr_sample", error_class: "StandardError" } ]
    )

    described_class.perform_now(dry_run: false)

    expect(AuditLog.last).to have_attributes(
      action: "contact_requests.retention_cleanup.execute",
      outcome: "failed",
      error_code: "partial_cleanup_failure"
    )
  end

  it "success audit失敗時はanonymizeをrollbackしてfailed auditだけを残す" do
    expired = create(:contact_request, status: "resolved", handled_at: 181.days.ago, body: "PII body")
    allow(AuditLogs).to receive(:record_system_action!).and_wrap_original do |original, **attributes|
      raise ActiveRecord::RecordInvalid, AuditLog.new if attributes[:outcome] == "succeeded"

      original.call(**attributes)
    end

    expect do
      described_class.perform_now(dry_run: false)
    end.to raise_error(ActiveRecord::RecordInvalid)

    aggregate_failures do
      expect(expired.reload.body).to eq("PII body")
      expect(AuditLog.last).to have_attributes(outcome: "failed", error_code: "cleanup_failed")
    end
  end

  it "SystemSettingsの保持期間をdry-run audit metadataへ反映しPIIを残さない" do
    create(
      :system_setting,
      key: "retention.contact_requests_days",
      value: SystemSettings.stored_value(90)
    )
    expired = create(
      :contact_request,
      status: "resolved",
      handled_at: 91.days.ago,
      email: "secret@example.com",
      body: "secret body",
      user_agent: "Sensitive Browser"
    )
    create(:contact_request, status: "resolved", handled_at: 89.days.ago)

    expect do
      described_class.perform_now
    end.to change(AuditLog, :count).by(1)

    audit_log = AuditLog.last
    metadata_json = audit_log.metadata.to_json

    aggregate_failures do
      expect(audit_log).to have_attributes(
        actor_kind: "system",
        action: "contact_requests.retention_cleanup.dry_run",
        outcome: "succeeded"
      )
      expect(audit_log.metadata).to include(
        "dry_run" => true,
        "retention_days" => 90,
        "candidate_count" => 1,
        "anonymized_count" => 0,
        "failed_count" => 0
      )
      expect(audit_log.metadata["cutoff"]).to eq(90.days.ago.iso8601)
      expect(metadata_json).not_to include(expired.request_uid)
      expect(metadata_json).not_to include("secret@example.com")
      expect(metadata_json).not_to include("secret body")
      expect(metadata_json).not_to include("Sensitive Browser")
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
