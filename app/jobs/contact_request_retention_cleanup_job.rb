class ContactRequestRetentionCleanupJob < ApplicationJob
  queue_as :default

  DEFAULT_LIMIT = 1000
  DRY_RUN_AUDIT_ACTION = "contact_requests.retention_cleanup.dry_run".freeze
  EXECUTE_AUDIT_ACTION = "contact_requests.retention_cleanup.execute".freeze

  def perform(dry_run: true, now: Time.current, limit: DEFAULT_LIMIT)
    dry_run = normalize_boolean(dry_run)
    result = ContactRequests.cleanup_retention(
      dry_run: dry_run,
      now: now,
      limit: limit
    )

    log_completion(result)
    record_audit!(result, dry_run: dry_run, now: now, limit: limit)
    result
  rescue StandardError => e
    record_failed_audit!(dry_run: dry_run, now: now, limit: limit, error: e)
    raise
  end

  private

  def log_completion(result)
    Rails.logger.info(
      "[ContactRequestRetentionCleanupJob] completed " \
      "dry_run=#{result[:dry_run]} candidate_count=#{result[:candidate_count]} " \
      "anonymized_count=#{result[:anonymized_count]} failed_count=#{result[:failed_count]} " \
      "sample_request_uids=#{Array(result[:sample_request_uids]).first(5).join(',')}"
    )
  end

  def record_audit!(result, dry_run:, now:, limit:)
    AuditLogs.record_system_action!(
      action: audit_action(dry_run),
      outcome: "succeeded",
      metadata: {
        dry_run: result.fetch(:dry_run, dry_run),
        cutoff: audit_time(result[:cutoff] || ContactRequests.retention_cutoff(now: now)),
        retention_days: result[:retention_days] || ContactRequests.contact_request_retention_days,
        limit: result[:limit] || limit,
        candidate_count: result[:candidate_count],
        anonymized_count: result[:anonymized_count],
        failed_count: result[:failed_count]
      }
    )
  end

  def record_failed_audit!(dry_run:, now:, limit:, error:)
    AuditLogs.record_system_action!(
      action: audit_action(dry_run),
      outcome: "failed",
      error_code: "cleanup_failed",
      metadata: {
        dry_run: dry_run,
        cutoff: audit_time(ContactRequests.retention_cutoff(now: now)),
        retention_days: ContactRequests.contact_request_retention_days,
        limit: limit,
        error_class: error.class.name
      }
    )
  end

  def audit_action(dry_run)
    dry_run ? DRY_RUN_AUDIT_ACTION : EXECUTE_AUDIT_ACTION
  end

  def audit_time(value)
    return value.iso8601 if value.respond_to?(:iso8601)

    value
  end

  def normalize_boolean(value)
    return true if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end
end
