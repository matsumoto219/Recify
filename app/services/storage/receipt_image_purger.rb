module Storage
  class ReceiptImagePurger
    DEFAULT_LIMIT = 100
    DEFAULT_RETENTION_DAYS = 1
    RETENTION_DAYS_KEY = "retention.receipt_images_days"
    SAMPLE_LIMIT = 20

    def self.call(...)
      new(...).call
    end

    def self.retention_days
      SystemSettings.limit_for(RETENTION_DAYS_KEY)
    rescue StandardError
      DEFAULT_RETENTION_DAYS
    end

    def initialize(dry_run: true, limit: DEFAULT_LIMIT, cutoff: Time.current)
      @dry_run = normalize_boolean(dry_run)
      @limit = normalize_limit(limit)
      @retention_days = self.class.retention_days
      @cutoff = normalize_cutoff(cutoff) - retention_days.days
    end

    def call
      records = candidates.map { |receipt| receipt_record(receipt) }
      result = {
        dry_run: dry_run,
        cutoff: cutoff,
        retention_days: retention_days,
        limit: limit,
        candidate_count: records.size,
        purged_count: 0,
        skipped_count: dry_run ? records.size : 0,
        failed_count: 0,
        sample_receipt_ids: records.map { |record| record[:receipt_id] }.first(SAMPLE_LIMIT),
        sample_receipt_public_ids: records.map { |record| record[:receipt_public_id] }.first(SAMPLE_LIMIT),
        records: records,
        errors: []
      }

      return result if dry_run

      purge_candidates!(result)
      result
    end

    private

    attr_reader :dry_run, :limit, :cutoff, :retention_days

    def candidates
      @candidates ||= Receipt
        .joins(:image_attachment)
        .where(keep_image: false, image_purged_at: nil, image_purged_reason: nil)
        .where.not(image_purge_eligible_at: nil)
        .where(image_purge_eligible_at: ..cutoff)
        .where.not(status: "processing")
        .where.not(id: ReceiptAnalysisRun.active.select(:receipt_id))
        .order(:image_purge_eligible_at, :id)
        .limit(limit)
        .to_a
    end

    def purge_candidates!(result)
      result[:skipped_count] = 0

      candidates.each do |receipt|
        unless purgeable_now?(receipt)
          result[:skipped_count] += 1
          next
        end

        Storage::AttachmentPurger.call(receipt.image)
        receipt.mark_image_purged!(reason: Receipt::IMAGE_PURGED_REASON_SYSTEM_PURGE)
        result[:purged_count] += 1
      rescue StandardError => e
        result[:failed_count] += 1
        result[:errors] << purge_error_record(receipt, e)
      end
    end

    def purgeable_now?(receipt)
      receipt.reload

      receipt.image_retention_disabled? &&
        receipt.image.attached? &&
        receipt.image_purged_at.nil? &&
        receipt.image_purged_reason.nil? &&
        receipt.image_purge_eligible_at.present? &&
        receipt.image_purge_eligible_at <= cutoff &&
        !receipt.processing? &&
        !receipt.receipt_analysis_runs.active.exists?
    end

    def receipt_record(receipt)
      {
        receipt_id: receipt.id,
        receipt_public_id: receipt.public_id,
        status: receipt.status,
        image_purge_eligible_at: receipt.image_purge_eligible_at
      }
    end

    def purge_error_record(receipt, error)
      {
        receipt_id: receipt&.id,
        receipt_public_id: receipt&.public_id,
        error_class: error.class.name,
        error_message: error.message
      }
    end

    def normalize_boolean(value)
      return true if value.nil?

      ActiveModel::Type::Boolean.new.cast(value)
    end

    def normalize_limit(value)
      integer = value.to_i

      integer.positive? ? integer : DEFAULT_LIMIT
    end

    def normalize_cutoff(value)
      return Time.current if value.blank?
      return value if value.respond_to?(:to_time)

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      Time.current
    end
  end
end
