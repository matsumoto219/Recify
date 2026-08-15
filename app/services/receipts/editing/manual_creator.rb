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

  def self.call(receipt:, attributes:, user:, items_missing:, source_attributes: attributes)
    new(receipt:, attributes:, source_attributes:, user:, items_missing:).call
  end

  def initialize(receipt:, attributes:, source_attributes:, user:, items_missing:)
    @receipt = receipt
    @attributes = attributes
    @source_attributes = source_attributes
    @user = user
    @items_missing = items_missing == true
    @initial_attributes = receipt.attributes.deep_dup
  end

  def call
    receipt.assign_attributes(items_missing ? source_attributes : attributes)
    apply_status!(items_missing ? receipt.review_reasons : attributes["review_reasons"])
    return result(saved: false) if items_missing

    saved = persist_receipt
    restore_source_after_failure unless saved

    result(saved: saved)
  rescue Usage::LimitExceeded
    restore_source_after_failure
    raise
  end

  private

  attr_reader :receipt, :attributes, :source_attributes, :user, :items_missing, :initial_attributes

  def restore_source_after_failure
    error_snapshot = validation_error_snapshot
    reset_nested_associations!
    receipt.assign_attributes(initial_attributes)
    receipt.assign_attributes(source_attributes)
    apply_status!(receipt.review_reasons)
    restore_record_errors(receipt, error_snapshot[:receipt])
    error_snapshot[:children].each do |association_name, child_errors|
      receipt.public_send(association_name).zip(child_errors).each do |record, errors|
        restore_record_errors(record, errors)
      end
    end
  end

  def reset_nested_associations!
    %i[receipt_items receipt_adjustments receipt_payments receipt_tax_details].each do |association_name|
      receipt.association(association_name).reset
    end
  end

  def apply_status!(review_reasons)
    receipt.status = Array(review_reasons).empty? ? "completed" : "review_needed"
  end

  def validation_error_snapshot
    {
      receipt: record_error_snapshot(receipt),
      children: %i[receipt_items receipt_adjustments receipt_payments].to_h do |association_name|
        [ association_name, receipt.public_send(association_name).map { |record| record_error_snapshot(record) } ]
      end
    }
  end

  def record_error_snapshot(record)
    record.errors.objects.dup
  end

  def restore_record_errors(record, errors)
    record.errors.clear
    errors.each { |error| record.errors.import(error) }
  end

  def persist_receipt
    return persist_with_usage unless uploaded_image

    Storage.with_quota_reservation(byte_size: uploaded_image.size, user: user) { persist_with_usage }
  rescue Storage::QuotaExceeded
    receipt.errors.add(:image, :storage_quota_exceeded)
    false
  end

  def persist_with_usage
    saved = false
    previous_manual_core_fields_required = receipt.manual_core_fields_required
    receipt.manual_core_fields_required = true

    ActiveRecord::Base.transaction(requires_new: true) do
      if receipt.valid?
        Usage.consume_manual_receipt!(user: user)
        saved = receipt.save
      end

      raise ActiveRecord::Rollback unless saved
    end

    saved
  ensure
    receipt.manual_core_fields_required = previous_manual_core_fields_required
  end

  def uploaded_image
    attributes["image"]
  end

  def result(saved:)
    Result.new(receipt:, saved:, items_missing:)
  end
end
