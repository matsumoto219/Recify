class AuditLogRetentionCleanupJob < ApplicationJob
  queue_as :default

  DEFAULT_LIMIT = 1000
  AUDIT_ACTION = "audit_logs.retention_cleanup.dry_run".freeze
  SAMPLE_AUDIT_ID_LIMIT = 20

  def perform(categories: nil, now: Time.current, limit: DEFAULT_LIMIT, dry_run: true)
    result = AuditLogs.cleanup_retention(
      categories: categories,
      now: now,
      limit: limit,
      dry_run: dry_run
    )

    log_completion(result)
    record_audit!(result, categories: categories, now: now, limit: limit, dry_run: dry_run)
    result
  rescue StandardError => e
    record_failed_audit!(categories: categories, now: now, limit: limit, dry_run: dry_run, error: e)
    raise
  end

  private

  def log_completion(result)
    Rails.logger.info(
      "[AuditLogRetentionCleanupJob] completed " \
      "dry_run=#{result[:dry_run]} expired_count=#{result[:expired_count]} " \
      "deleted_count=#{result[:deleted_count]}"
    )
  end

  def record_audit!(result, categories:, now:, limit:, dry_run:)
    AuditLogs.record_system_action!(
      action: AUDIT_ACTION,
      outcome: "succeeded",
      metadata: {
        dry_run: result.fetch(:dry_run, dry_run),
        categories: result[:categories] || Array(categories),
        cutoffs: result[:cutoffs] || {},
        limit: limit,
        expired_count: result[:expired_count],
        deleted_count: result[:deleted_count],
        sample_audit_ids: sample_audit_ids(result)
      }
    )
  end

  def record_failed_audit!(categories:, now:, limit:, dry_run:, error:)
    AuditLogs.record_system_action!(
      action: AUDIT_ACTION,
      outcome: "failed",
      error_code: "cleanup_failed",
      metadata: {
        dry_run: dry_run,
        categories: Array(categories),
        now: audit_time(now),
        limit: limit,
        error_class: error.class.name,
        sample_audit_ids: []
      }
    )
  end

  def sample_audit_ids(result)
    Array(result[:sample_audit_ids]).first(SAMPLE_AUDIT_ID_LIMIT)
  end

  def audit_time(value)
    return value.iso8601 if value.respond_to?(:iso8601)

    value
  end
end
