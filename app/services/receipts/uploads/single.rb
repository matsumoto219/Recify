class Receipts::Uploads::Single
  Result = Data.define(:receipt, :saved, :enqueue_succeeded) do
    def saved?
      saved == true
    end

    def enqueue_succeeded?
      enqueue_succeeded == true
    end
  end
  private_constant :Result

  def self.call(user:, image:, operation: nil)
    new(user:, image:, operation:).call
  end

  def initialize(user:, image:, operation:)
    @user = user
    @image = image
    @operation = operation
  end

  def call
    receipt = user.receipts.new(
      image: image,
      keep_image: user.effective_keep_receipt_images,
      status: "processing"
    )
    saved = save_with_usage!(receipt)
    unless saved
      if operation && receipt.errors.of_kind?(:image, :upload_failed)
        Receipts::Registrations.report_failure(operation:, reason: "storage_failed")
      end
      return Result.new(receipt:, saved: false, enqueue_succeeded: false)
    end

    Result.new(receipt:, saved: true, enqueue_succeeded: enqueue_analysis(receipt))
  end

  private

  attr_reader :user, :image, :operation

  def save_with_usage!(receipt)
    saved = false

    prepared = Storage.with_prepared_images(
      records: [ receipt ],
      attachment_name: :image,
      user: user,
      registration_key: operation&.operation_key
    ) do
      ActiveRecord::Base.transaction(requires_new: true) do
        Usage.consume_receipt_upload!(user: user)
        saved = receipt.save
        raise ActiveRecord::Rollback unless saved

        Receipts::Registrations.accept!(operation:, receipts: [ receipt ]) if operation
      end
      saved
    end

    saved && prepared
  rescue Storage::QuotaExceeded
    receipt.errors.add(:image, :storage_quota_exceeded)
    false
  end

  def enqueue_analysis(receipt)
    result = Receipts::Processing.start(
      receipt: receipt,
      source: "upload",
      requested_by_user: user
    )

    unless result.created?
      Rails.logger.info(
        "[ReceiptAnalysis] skip_enqueue_existing_run receipt_id=#{receipt.id} run_id=#{result.run.id} user_id=#{user.id}"
      )
      return true
    end

    Rails.logger.info(
      "[ReceiptAnalysis] enqueue receipt_id=#{receipt.id} run_id=#{result.run.id} user_id=#{user.id} image_attached=#{receipt.image.attached?}"
    )

    Receipts::Processing.enqueue(result.run, job_class: ReceiptOcrJob)
    true
  rescue Receipts::Processing::EnqueueError, ExternalServices::RuntimeConfigUnavailableError
    false
  end
end
