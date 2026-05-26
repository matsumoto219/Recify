class ReceiptAnalysisRunRetentionCleanupJob < ApplicationJob
  queue_as :default

  DEFAULT_LIMIT = 1000

  def perform(cutoff: Time.current, limit: DEFAULT_LIMIT, dry_run: true)
    result = ReceiptAnalysisRuns.cleanup_expired(
      cutoff: cutoff,
      limit: limit,
      dry_run: dry_run
    )

    log_completion(result)
    result
  end

  private

  def log_completion(result)
    Rails.logger.info(
      "[ReceiptAnalysisRunRetentionCleanupJob] completed " \
      "dry_run=#{result[:dry_run]} expired_count=#{result[:expired_count]} " \
      "deleted_count=#{result[:deleted_count]}"
    )
  end
end
