class AuditLogRetentionCleanupJob < ApplicationJob
  queue_as :default

  DEFAULT_LIMIT = 1000
  DRY_RUN_AUDIT_ACTION = "audit_logs.retention_cleanup.dry_run".freeze
  EXECUTE_AUDIT_ACTION = "audit_logs.retention_cleanup.execute".freeze
  SAMPLE_AUDIT_ID_LIMIT = 20

  def perform(categories: nil, now: Time.current, limit: DEFAULT_LIMIT, dry_run: true)
    dry_run = normalize_boolean(dry_run)
    result = nil
    AuditLog.transaction do
      result = AuditLogs.cleanup_retention(
        categories: categories,
        now: now,
        limit: limit,
        dry_run: dry_run
      )
      record_audit!(result, categories: categories, now: now, limit: limit, dry_run: dry_run)
    end

    log_completion(result)
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
    failed = partial_failure?(result)
    AuditLogs.record_system_action!(
      action: audit_action(dry_run),
      outcome: failed ? "failed" : "succeeded",
      error_code: failed ? "partial_cleanup_failure" : nil,
      metadata: {
        dry_run: result.fetch(:dry_run, dry_run),
        categories: result[:categories] || Array(categories),
        cutoffs: result[:cutoffs] || {},
        limit: limit,
        expired_count: result[:expired_count],
        deleted_count: result[:deleted_count],
        failed_count: result[:failed_count].to_i,
        sample_audit_ids: sample_audit_ids(result)
      }
    )
  end

  def record_failed_audit!(categories:, now:, limit:, dry_run:, error:)
    AuditLogs.record_system_action!(
      action: audit_action(dry_run),
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

  def audit_action(dry_run)
    dry_run ? DRY_RUN_AUDIT_ACTION : EXECUTE_AUDIT_ACTION
  end

  def partial_failure?(result)
    result[:failed_count].to_i.positive? || Array(result[:errors]).any?
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
