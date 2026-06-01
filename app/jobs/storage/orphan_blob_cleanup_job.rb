module Storage
  class OrphanBlobCleanupJob < ApplicationJob
    queue_as :default

    DEFAULT_LIMIT = 100

    def perform(dry_run: true, limit: DEFAULT_LIMIT, created_before: nil, older_than: nil)
      dry_run = normalize_boolean(dry_run)
      scan = Storage.orphan_blob_scan(
        created_before: created_before,
        older_than: older_than,
        limit: normalize_limit(limit)
      )
      result = cleanup_result(scan:, dry_run:)

      purge_blobs!(scan, result) unless dry_run

      log_completion(result)
      result
    end

    private

    def cleanup_result(scan:, dry_run:)
      {
        dry_run: dry_run,
        scanned_count: scan.fetch(:count),
        purged_count: 0,
        skipped_count: dry_run ? scan.fetch(:count) : 0,
        bytes: scan.fetch(:bytes),
        failed_count: 0
      }
    end

    def purge_blobs!(scan, result)
      ActiveStorage::Blob.where(id: scan.fetch(:blob_ids)).find_each do |blob|
        if blob.attachments.exists?
          result[:skipped_count] += 1
          next
        end

        blob.purge
        result[:purged_count] += 1
      rescue StandardError => e
        result[:failed_count] += 1
        log_purge_failure(blob, e)
      end
    end

    def normalize_boolean(value)
      return true if value.nil?

      ActiveModel::Type::Boolean.new.cast(value)
    end

    def normalize_limit(value)
      integer = value.to_i

      integer.positive? ? integer : DEFAULT_LIMIT
    end

    def log_purge_failure(blob, error)
      Rails.logger.error(
        "[Storage::OrphanBlobCleanupJob] failed blob_id=#{blob&.id} " \
        "error_class=#{error.class} message=#{error.message}"
      )
    end

    def log_completion(result)
      Rails.logger.info(
        "[Storage::OrphanBlobCleanupJob] completed " \
        "dry_run=#{result[:dry_run]} scanned_count=#{result[:scanned_count]} " \
        "purged_count=#{result[:purged_count]} skipped_count=#{result[:skipped_count]} " \
        "bytes=#{result[:bytes]} failed_count=#{result[:failed_count]}"
      )
    end
  end
end
