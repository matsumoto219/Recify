module Storage
  class ReceiptImagePurgeJob < ApplicationJob
    queue_as :default

    DEFAULT_LIMIT = 100
    SAMPLE_RECEIPT_LIMIT = 20
    DRY_RUN_AUDIT_ACTION = "receipt_images.purge.dry_run".freeze
    EXECUTE_AUDIT_ACTION = "receipt_images.purge.execute".freeze

    def perform(dry_run: true, limit: DEFAULT_LIMIT, cutoff: Time.current)
      dry_run = normalize_boolean(dry_run)
      result = nil
      AuditLog.transaction do
        result = Storage.purge_receipt_images(
          dry_run: dry_run,
          limit: limit,
          cutoff: cutoff
        )
        record_audit!(result, dry_run: dry_run, limit: limit, cutoff: cutoff)
      end

      log_completion(result)
      result
    rescue StandardError => e
      record_failed_audit!(dry_run: dry_run, limit: limit, cutoff: cutoff, error: e)
      raise
    end

    private

    def log_completion(result)
      Rails.logger.info(
        "[Storage::ReceiptImagePurgeJob] completed " \
        "dry_run=#{result[:dry_run]} candidate_count=#{result[:candidate_count]} " \
        "purged_count=#{result[:purged_count]} skipped_count=#{result[:skipped_count]} " \
        "failed_count=#{result[:failed_count]}"
      )
    end

    def record_audit!(result, dry_run:, limit:, cutoff:)
      failed = result[:failed_count].to_i.positive?
      AuditLogs.record_system_action!(
        action: audit_action(dry_run),
        outcome: failed ? "failed" : "succeeded",
        error_code: failed ? "partial_purge_failure" : nil,
        metadata: {
          dry_run: result.fetch(:dry_run, dry_run),
          cutoff: audit_time(result[:cutoff] || cutoff),
          retention_days: result[:retention_days],
          limit: result[:limit] || limit,
          candidate_count: result[:candidate_count],
          purged_count: result[:purged_count],
          skipped_count: result[:skipped_count],
          failed_count: result[:failed_count],
          sample_receipt_ids: sample_receipt_ids(result),
          sample_receipt_public_ids: sample_receipt_public_ids(result)
        }
      )
    end

    def record_failed_audit!(dry_run:, limit:, cutoff:, error:)
      AuditLogs.record_system_action!(
        action: audit_action(dry_run),
        outcome: "failed",
        error_code: "purge_failed",
        metadata: {
          dry_run: dry_run,
          cutoff: audit_time(cutoff),
          limit: limit,
          error_class: error.class.name,
          sample_receipt_ids: [],
          sample_receipt_public_ids: []
        }
      )
    end

    def audit_action(dry_run)
      dry_run ? DRY_RUN_AUDIT_ACTION : EXECUTE_AUDIT_ACTION
    end

    def sample_receipt_ids(result)
      Array(result[:sample_receipt_ids]).first(SAMPLE_RECEIPT_LIMIT)
    end

    def sample_receipt_public_ids(result)
      Array(result[:sample_receipt_public_ids]).first(SAMPLE_RECEIPT_LIMIT)
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
end
