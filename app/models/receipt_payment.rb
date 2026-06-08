class ReceiptPayment < ApplicationRecord
  DEFAULT_MAX_PER_RECEIPT = 20
  MAX_PER_RECEIPT = DEFAULT_MAX_PER_RECEIPT

  belongs_to :receipt

  validates :amount,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: ->(_payment) { ReceiptAmountLimits.receipt_payment_amount_max }
            },
            allow_nil: true
  validate :payments_per_receipt_within_limit, on: :create

  def self.per_receipt_limit
    SystemSettings.limit_for("limits.receipt_payments_per_receipt")
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
    DEFAULT_MAX_PER_RECEIPT
  end

  private

  def payments_per_receipt_within_limit
    return if receipt.blank?
    limit = self.class.per_receipt_limit
    return if sibling_count_for_limit(:receipt_payments) < limit

    errors.add(:receipt, :receipt_payments_limit_exceeded, limit: limit)
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
