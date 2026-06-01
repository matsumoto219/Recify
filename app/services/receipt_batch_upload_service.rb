class ReceiptBatchUploadService
  MAX_FILES = 5
  private_constant :MAX_FILES

  Result = Struct.new(:created_receipts, :errors, keyword_init: true) do
    def success?
      errors.blank?
    end

    def count
      created_receipts.size
    end
  end

  def self.call(user:, files:)
    new(user:, files:).call
  end

  def self.max_files
    MAX_FILES
  end

  def initialize(user:, files:)
    @user = user
    @files = Array(files).compact_blank
  end

  def call
    return failure(I18n.t("receipts.batch_upload.errors.empty")) if files.blank?
    return failure(I18n.t("receipts.batch_upload.errors.too_many", max: MAX_FILES)) if files.size > MAX_FILES
    return failure(I18n.t("receipts.batch_upload.errors.quota_exceeded")) unless storage_quota_available?

    create_receipts
  rescue UsageLimits::LimitExceeded
    failure(I18n.t("receipts.batch_upload.errors.usage_limit_exceeded"))
  end

  private

  attr_reader :user, :files

  def create_receipts
    created_receipts = []
    validation_errors = []

    ActiveRecord::Base.transaction do
      consume_batch_upload_limits!

      files.each do |file|
        receipt = user.receipts.new(image: file, status: "processing")

        unless receipt.save
          validation_errors = receipt.errors.full_messages
          raise ActiveRecord::Rollback
        end

        created_receipts << receipt
      end
    end

    return failure(validation_errors) if validation_errors.any?

    enqueue_analysis_jobs(created_receipts)
    success(created_receipts)
  end

  def storage_quota_available?
    total_size = files.sum { |file| file.respond_to?(:size) ? file.size.to_i : 0 }

    user.storage_can_add?(total_size)
  end

  def consume_batch_upload_limits!
    UsageCounters.check_and_increment!(
      user: user,
      key: "batch_files_per_day",
      amount: files.size,
      limit: UserLimits.effective_limit(user: user, key: "batch_files_per_day")
    )
  end

  def enqueue_analysis_jobs(receipts)
    receipts.each do |receipt|
      result = ReceiptAnalysisRuns.start(
        receipt: receipt,
        source: "batch_upload",
        requested_by_user: user
      )

      unless result.created?
        Rails.logger.info(
          "[ReceiptAnalysis] skip_enqueue_existing_run receipt_id=#{receipt.id} run_id=#{result.run.id} user_id=#{user.id}"
        )
        next
      end

      Rails.logger.info(
        "[ReceiptAnalysis] enqueue receipt_id=#{receipt.id} run_id=#{result.run.id} user_id=#{user.id} image_attached=#{receipt.image.attached?}"
      )
      unless consume_ocr_job_limit_for!(result.run)
        Rails.logger.info(
          "[ReceiptAnalysis] blocked_enqueue_usage_limit receipt_id=#{receipt.id} run_id=#{result.run.id} user_id=#{user.id}"
        )
        next
      end

      ReceiptOcrJob.perform_later(run_id: result.run.id)
    end
  end

  def consume_ocr_job_limit_for!(run)
    UsageLimits.consume_ocr_job!(user: user)
    true
  rescue UsageLimits::LimitExceeded
    UsageLimits.mark_analysis_run_blocked!(run: run, stage: "ocr")
    false
  end

  def success(created_receipts)
    Result.new(created_receipts:, errors: [])
  end

  def failure(errors)
    Result.new(created_receipts: [], errors: Array(errors))
  end
end
