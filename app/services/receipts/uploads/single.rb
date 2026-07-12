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

  def self.call(user:, image:)
    new(user:, image:).call
  end

  def initialize(user:, image:)
    @user = user
    @image = image
  end

  def call
    receipt = user.receipts.new(
      image: image,
      keep_image: user.effective_keep_receipt_images,
      status: "processing"
    )
    saved = save_with_usage!(receipt)
    return Result.new(receipt:, saved: false, enqueue_succeeded: false) unless saved

    Result.new(receipt:, saved: true, enqueue_succeeded: enqueue_analysis(receipt))
  end

  private

  attr_reader :user, :image

  def save_with_usage!(receipt)
    saved = false

    Storage.with_quota_reservation(byte_size: image.size, user: user) do
      ActiveRecord::Base.transaction(requires_new: true) do
        Usage.consume_receipt_upload!(user: user)
        saved = receipt.save
        raise ActiveRecord::Rollback unless saved
      end
    end

    saved
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
