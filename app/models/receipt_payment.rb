class ReceiptPayment < ApplicationRecord
  MAX_PER_RECEIPT = 20

  belongs_to :receipt

  validate :payments_per_receipt_within_limit, on: :create

  private

  def payments_per_receipt_within_limit
    return if receipt.blank?
    return if sibling_count_for_limit(:receipt_payments) < MAX_PER_RECEIPT

    errors.add(:receipt, :receipt_payments_limit_exceeded, limit: MAX_PER_RECEIPT)
  end

  def sibling_count_for_limit(association_name)
    association_proxy = receipt.association(association_name)
    target = association_proxy.target

    if association_proxy.loaded? || target.any?
      target.reject { |record| record.equal?(self) || record.marked_for_destruction? }.size
    else
      scope = receipt.public_send(association_name)
      scope = scope.where.not(id: id) if id.present?
      scope.count
    end
  end
end
