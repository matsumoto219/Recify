class Receipts::Editing::ManualCreator
  Result = Data.define(:receipt, :saved, :items_missing) do
    def saved?
      saved == true
    end

    def items_missing?
      items_missing == true
    end
  end
  private_constant :Result

  def self.call(receipt:, attributes:, user:, items_missing:)
    new(receipt:, attributes:, user:, items_missing:).call
  end

  def initialize(receipt:, attributes:, user:, items_missing:)
    @receipt = receipt
    @attributes = attributes
    @user = user
    @items_missing = items_missing == true
  end

  def call
    receipt.assign_attributes(attributes)
    receipt.status = attributes["review_reasons"].empty? ? "completed" : "review_needed"
    return result(saved: false) if items_missing

    saved = persist_receipt

    result(saved: saved)
  end

  private

  attr_reader :receipt, :attributes, :user, :items_missing

  def persist_receipt
    return persist_with_usage unless uploaded_image

    Storage.with_quota_reservation(byte_size: uploaded_image.size, user: user) { persist_with_usage }
  rescue Storage::QuotaExceeded
    receipt.errors.add(:image, :storage_quota_exceeded)
    false
  end

  def persist_with_usage
    saved = false

    ActiveRecord::Base.transaction(requires_new: true) do
      if receipt.valid?
        Usage.consume_manual_receipt!(user: user)
        saved = receipt.save
      end

      raise ActiveRecord::Rollback unless saved
    end

    saved
  end

  def uploaded_image
    attributes["image"]
  end

  def result(saved:)
    Result.new(receipt:, saved:, items_missing:)
  end
end
