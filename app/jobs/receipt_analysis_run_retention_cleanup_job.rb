class ReceiptAnalysisRunRetentionCleanupJob < ApplicationJob
  queue_as :default

  DEFAULT_LIMIT = 1000
  AUDIT_ACTION = "receipt_analysis_runs.cleanup_expired.dry_run".freeze
  SAMPLE_RUN_KEY_LIMIT = 20

  def perform(cutoff: Time.current, limit: DEFAULT_LIMIT, dry_run: true)
    result = ReceiptAnalysisRuns.cleanup_expired(
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
      "[ReceiptAnalysisRunRetentionCleanupJob] completed " \
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
        sample_run_keys: sample_run_keys(result)
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
        sample_run_keys: []
      }
    )
  end

  def sample_run_keys(result)
    Array(result[:records])
      .filter_map { |record| record[:run_key].presence }
      .first(SAMPLE_RUN_KEY_LIMIT)
  end

  def audit_time(value)
    return value.iso8601 if value.respond_to?(:iso8601)

    value
  end
end
