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

  def self.call(receipt:, attributes:, items_missing:, source_attributes: attributes)
    new(receipt:, attributes:, source_attributes:, items_missing:).call
  end

  def initialize(receipt:, attributes:, source_attributes:, items_missing:)
    @receipt = receipt
    @attributes = attributes
    @source_attributes = source_attributes
    @items_missing = items_missing == true
  end

  def call
    if items_missing
      receipt.assign_attributes(source_attributes)
      return result(saved: false)
    end

    saved = persist_update
    restore_source_after_failure unless saved
    result(saved: saved)
  end

  private

  attr_reader :receipt, :attributes, :source_attributes, :items_missing

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

  def restore_source_after_failure
    error_snapshot = validation_error_snapshot

    receipt.reload
    receipt.assign_attributes(source_attributes)
    restore_record_errors(receipt, error_snapshot[:receipt])
    error_snapshot[:children].each do |association_name, child_snapshot|
      restore_child_errors(receipt.public_send(association_name), child_snapshot)
    end
  end

  def validation_error_snapshot
    {
      receipt: record_error_snapshot(receipt),
      children: %i[receipt_items receipt_adjustments receipt_payments].to_h do |association_name|
        [ association_name, child_error_snapshot(receipt.public_send(association_name)) ]
      end
    }
  end

  def child_error_snapshot(records)
    {
      persisted: records.select(&:persisted?).to_h do |record|
        [ record.id.to_s, record_error_snapshot(record) ]
      end,
      new: records.reject(&:persisted?).map { |record| record_error_snapshot(record) }
    }
  end

  def restore_child_errors(records, snapshot)
    records.select(&:persisted?).each do |record|
      restore_record_errors(record, snapshot[:persisted].fetch(record.id.to_s, []))
    end
    records.reject(&:persisted?).zip(snapshot[:new]).each do |record, errors|
      restore_record_errors(record, errors || [])
    end
  end

  def record_error_snapshot(record)
    record.errors.objects.dup
  end

  def restore_record_errors(record, errors)
    record.errors.clear
    errors.each { |error| record.errors.import(error) }
  end

  def result(saved:)
    Result.new(receipt:, saved:, items_missing:)
  end
end
