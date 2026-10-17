class Receipts::Uploads::Batch
  DEFAULT_MAX_FILES = 5
  MAX_FILES = DEFAULT_MAX_FILES
  private_constant :MAX_FILES

  def self.call(user:, files:, operation: nil)
    new(user:, files:, operation:).call
  end

  def self.max_files
    SystemSettings.limit_for("limits.batch_upload_max_files")
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
    DEFAULT_MAX_FILES
  end

  def initialize(user:, files:, operation:)
    @user = user
    @files = Array(files).compact_blank
    @operation = operation
  end

  def call
    return failure(I18n.t("receipts.batch_upload.errors.empty")) if files.blank?
    return failure(I18n.t("receipts.batch_upload.errors.too_many", max: max_files)) if files.size > max_files
    return failure(I18n.t("flash.receipts.ocr_unavailable")) if ExternalServices.down?(:ocr)
    return failure(storage_quota_error_message) unless storage_quota_available?

    create_receipts
  rescue Usage::LimitExceeded
    failure(I18n.t("receipts.batch_upload.errors.usage_limit_exceeded"))
  rescue Storage::QuotaExceeded => error
    failure(storage_quota_error_message(scope: error.scope))
  end

  private

  attr_reader :user, :files, :operation

  def max_files
    self.class.max_files
  end

  def create_receipts
    created_receipts = files.map do |file|
      user.receipts.new(image: file, status: "processing", keep_image: user.effective_keep_receipt_images)
    end
    validation_errors = []

    prepared = Storage.with_prepared_images(
      records: created_receipts,
      attachment_name: :image,
      user: user,
      registration_key: operation&.operation_key
    ) do
      ActiveRecord::Base.transaction(requires_new: true) do
        consume_batch_upload_limits!

        created_receipts.each do |receipt|
          unless receipt.save
            validation_errors = receipt.errors.full_messages
            raise ActiveRecord::Rollback
          end
        end

        Receipts::Registrations.accept!(operation:, receipts: created_receipts) if operation
      end
      validation_errors.empty?
    end

    return failure(validation_errors) if validation_errors.any?
    unless prepared
      if operation && created_receipts.any? { |receipt| receipt.errors.of_kind?(:image, :upload_failed) }
        Receipts::Registrations.report_failure(operation:, reason: "storage_failed")
      end
      return failure(created_receipts.flat_map { |receipt| receipt.errors.full_messages })
    end

    enqueue_errors = enqueue_analysis_jobs(created_receipts)
    success(created_receipts, errors: enqueue_errors)
  end

  def storage_quota_available?
    user.storage_can_add?(total_upload_size) && Storage.global_quota_can_add?(total_upload_size)
  end

  def total_upload_size
    @total_upload_size ||= files.sum { |file| file.respond_to?(:size) ? file.size.to_i : 0 }
  end

  def storage_quota_error_message(scope: nil)
    if scope == :global || !Storage.global_quota_can_add?(total_upload_size)
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
      result = Receipts::Processing.start(
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

      Receipts::Processing.enqueue(result.run, job_class: ReceiptOcrJob)
    rescue Receipts::Processing::EnqueueError, ExternalServices::RuntimeConfigUnavailableError
      errors << I18n.t("receipts.batch_upload.errors.analysis_enqueue_failed")
    end

    errors.uniq
  end

  def success(created_receipts, errors: [])
    Receipts::Uploads::Result.new(created_receipts:, errors: errors)
  end

  def failure(errors)
    Receipts::Uploads::Result.new(created_receipts: [], errors: Array(errors))
  end
end
