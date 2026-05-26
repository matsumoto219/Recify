class ReceiptAnalysisRunStaleCleanupJob < ApplicationJob
  queue_as :default

  DEFAULT_LIMIT = 100

  def perform(cutoff: 6.hours.ago, limit: DEFAULT_LIMIT, dry_run: true)
    result = ReceiptAnalysisRuns.cleanup_stale(
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
      "[ReceiptAnalysisRunStaleCleanupJob] completed " \
      "dry_run=#{result[:dry_run]} stale_count=#{result[:stale_count]} " \
      "failed_count=#{result[:failed_count]} canceled_count=#{result[:canceled_count]} " \
      "skipped_count=#{result[:skipped_count]} errors=#{result[:errors].size}"
    )
  end
end
