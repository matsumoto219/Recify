class UserSessionRetentionCleanupJob < ApplicationJob
  queue_as :default

  DEFAULT_LIMIT = 1000
  AUDIT_ACTION = "user_sessions.retention_cleanup.dry_run".freeze
  SAMPLE_SESSION_ID_LIMIT = 20

  def perform(cutoff: 90.days.ago, limit: DEFAULT_LIMIT, dry_run: true)
    result = UserSessions.cleanup_retention(
      cutoff: cutoff,
      limit: limit,
      dry_run: dry_run
    )

    log_completion(result)
    record_audit!(result, cutoff: cutoff, limit: limit, dry_run: dry_run)
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
    AuditLogs.record_system_action!(
      action: AUDIT_ACTION,
      outcome: "succeeded",
      metadata: {
        dry_run: result.fetch(:dry_run, dry_run),
        cutoff: audit_time(result[:cutoff] || cutoff),
        limit: result[:limit] || limit,
        expired_count: result[:expired_count],
        deleted_count: result[:deleted_count],
        sample_session_ids: sample_session_ids(result)
      }
    )
  end

  def record_failed_audit!(cutoff:, limit:, dry_run:, error:)
    AuditLogs.record_system_action!(
      action: AUDIT_ACTION,
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

  def audit_time(value)
    return value.iso8601 if value.respond_to?(:iso8601)

    value
  end
end
