class UserSessionRetentionCleanupJob < ApplicationJob
  queue_as :default

  DEFAULT_LIMIT = 1000
  DRY_RUN_AUDIT_ACTION = "user_sessions.retention_cleanup.dry_run".freeze
  EXECUTE_AUDIT_ACTION = "user_sessions.retention_cleanup.execute".freeze
  SAMPLE_SESSION_ID_LIMIT = 20

  def perform(cutoff: nil, limit: DEFAULT_LIMIT, dry_run: true)
    dry_run = normalize_boolean(dry_run)
    result = nil
    AuditLog.transaction do
      result = UserSessions.cleanup_retention(
        cutoff: cutoff,
        limit: limit,
        dry_run: dry_run
      )
      record_audit!(result, cutoff: cutoff, limit: limit, dry_run: dry_run)
    end

    log_completion(result)
    result
  rescue StandardError => e
    record_failed_audit!(cutoff: cutoff, limit: limit, dry_run: dry_run, error: e)
    raise
  end

  private

  def log_completion(result)
    Rails.logger.info(
      "[UserSessionRetentionCleanupJob] completed " \
      "dry_run=#{result[:dry_run]} expired_count=#{result[:expired_count]} " \
      "deleted_count=#{result[:deleted_count]}"
    )
  end

  def record_audit!(result, cutoff:, limit:, dry_run:)
    failed = partial_failure?(result)
    AuditLogs.record_system_action!(
      action: audit_action(dry_run),
      outcome: failed ? "failed" : "succeeded",
      error_code: failed ? "partial_cleanup_failure" : nil,
      metadata: {
        dry_run: result.fetch(:dry_run, dry_run),
        cutoff: audit_time(result[:cutoff] || cutoff),
        limit: result[:limit] || limit,
        expired_count: result[:expired_count],
        deleted_count: result[:deleted_count],
        skipped_count: result[:skipped_count].to_i,
        failed_count: result[:failed_count].to_i,
        sample_session_ids: sample_session_ids(result)
      }
    )
  end

  def record_failed_audit!(cutoff:, limit:, dry_run:, error:)
    AuditLogs.record_system_action!(
      action: audit_action(dry_run),
      outcome: "failed",
      error_code: "cleanup_failed",
      metadata: {
        dry_run: dry_run,
        cutoff: audit_time(cutoff),
        limit: limit,
        error_class: error.class.name,
        sample_session_ids: []
      }
    )
  end

  def sample_session_ids(result)
    Array(result[:sample_session_ids]).first(SAMPLE_SESSION_ID_LIMIT)
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
