class SecurityEventRetentionCleanupJob < ApplicationJob
  queue_as :default

  DEFAULT_LIMIT = 1000
  DRY_RUN_AUDIT_ACTION = "security_events.retention_cleanup.dry_run".freeze
  EXECUTE_AUDIT_ACTION = "security_events.retention_cleanup.execute".freeze
  SAMPLE_EVENT_ID_LIMIT = 20

  def perform(dry_run: true, now: Time.current, limit: DEFAULT_LIMIT)
    dry_run = normalize_boolean(dry_run)
    result = SecurityEvents.cleanup_retention(
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
      "[SecurityEventRetentionCleanupJob] completed " \
      "dry_run=#{result[:dry_run]} expired_count=#{result[:expired_count]} " \
      "deleted_count=#{result[:deleted_count]}"
    )
  end

  def record_audit!(result, dry_run:, now:, limit:)
    AuditLogs.record_system_action!(
      action: audit_action(dry_run),
      outcome: "succeeded",
      metadata: {
        dry_run: result.fetch(:dry_run, dry_run),
        now: audit_time(now),
        limit: limit,
        expired_count: result[:expired_count],
        deleted_count: result[:deleted_count],
        retentions: result[:retentions] || {},
        cutoffs: result[:cutoffs] || {},
        sample_event_ids: sample_event_ids(result)
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
        now: audit_time(now),
        limit: limit,
        error_class: error.class.name,
        sample_event_ids: []
      }
    )
  end

  def audit_action(dry_run)
    dry_run ? DRY_RUN_AUDIT_ACTION : EXECUTE_AUDIT_ACTION
  end

  def sample_event_ids(result)
    Array(result[:sample_event_ids]).first(SAMPLE_EVENT_ID_LIMIT)
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
