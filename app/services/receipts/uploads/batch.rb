class Receipts::Uploads::Batch
  DEFAULT_MAX_FILES = 5
  MAX_FILES = DEFAULT_MAX_FILES
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
    SystemSettings.limit_for("limits.batch_upload_max_files")
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
    DEFAULT_MAX_FILES
  end

  def initialize(user:, files:)
    @user = user
    @files = Array(files).compact_blank
  end

  def call
    return failure(I18n.t("receipts.batch_upload.errors.empty")) if files.blank?
    return failure(I18n.t("receipts.batch_upload.errors.too_many", max: max_files)) if files.size > max_files
    return failure(I18n.t("flash.receipts.ocr_unavailable")) if ExternalServices.down?(:ocr)
    return failure(storage_quota_error_message) unless storage_quota_available?

    create_receipts
  rescue Usage::LimitExceeded
    failure(I18n.t("receipts.batch_upload.errors.usage_limit_exceeded"))
  end

  private

  attr_reader :user, :files

  def max_files
    self.class.max_files
  end

  def create_receipts
    created_receipts = []
    validation_errors = []

    ActiveRecord::Base.transaction do
      consume_batch_upload_limits!

      files.each do |file|
        receipt = user.receipts.new(
          image: file,
          status: "processing",
          keep_image: user.effective_keep_receipt_images
        )

        unless receipt.save
          validation_errors = receipt.errors.full_messages
          raise ActiveRecord::Rollback
        end

        created_receipts << receipt
      end
    end

    return failure(validation_errors) if validation_errors.any?

    enqueue_errors = enqueue_analysis_jobs(created_receipts)
    success(created_receipts, errors: enqueue_errors)
  end

  def storage_quota_available?
    user.storage_can_add?(total_upload_size) && Storage.global_quota_can_add?(total_upload_size)
  end

  def total_upload_size
    @total_upload_size ||= files.sum { |file| file.respond_to?(:size) ? file.size.to_i : 0 }
  end

  def storage_quota_error_message
    if !Storage.global_quota_can_add?(total_upload_size)
      I18n.t("receipts.batch_upload.errors.global_hard_stop")
    else
      I18n.t("receipts.batch_upload.errors.quota_exceeded")
    end
  end

  def consume_batch_upload_limits!
    Usage.consume_batch_upload!(user: user, amount: files.size)
  end

  def enqueue_analysis_jobs(receipts)
    errors = []

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

      ReceiptAnalysisRuns.enqueue(result.run, job_class: ReceiptOcrJob)
    rescue ReceiptAnalysisRuns::EnqueueError, ExternalServices::RuntimeConfigUnavailableError
      errors << I18n.t("receipts.batch_upload.errors.analysis_enqueue_failed")
    end

    errors.uniq
  end

  def success(created_receipts, errors: [])
    Result.new(created_receipts:, errors: errors)
  end

  def failure(errors)
    Result.new(created_receipts: [], errors: Array(errors))
  end
end
