class Receipts::Editing::ManualUpdater
  Result = Data.define(:receipt, :saved, :items_missing) do
    def saved?
      saved == true
    end

    def items_missing?
      items_missing == true
    end
  end
  private_constant :Result

  def self.call(receipt:, attributes:, items_missing:)
    new(receipt:, attributes:, items_missing:).call
  end

  def initialize(receipt:, attributes:, items_missing:)
    @receipt = receipt
    @attributes = attributes
    @items_missing = items_missing == true
  end

  def call
    if items_missing
      receipt.assign_attributes(attributes)
      return result(saved: false)
    end

    result(saved: persist_update)
  end

  private

  attr_reader :receipt, :attributes, :items_missing

  def persist_update
    return receipt.update(attributes) unless uploaded_image

    Storage.with_quota_reservation(
      byte_size: uploaded_image.size,
      user: receipt.user,
      excluding_blob: existing_image_blob
    ) { receipt.update(attributes) }
  rescue Storage::QuotaExceeded
    receipt.errors.add(:image, :storage_quota_exceeded)
    false
  end

  def uploaded_image
    attributes["image"]
  end

  def existing_image_blob
    receipt.image.blob if receipt.image.attached?
  end

  def result(saved:)
    Result.new(receipt:, saved:, items_missing:)
  end
end
