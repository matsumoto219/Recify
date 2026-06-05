class ReceiptTaxDetail < ApplicationRecord
  MAX_PER_RECEIPT = 20

  belongs_to :receipt

  # --- Validations ---
  validates :rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :net_amount, numericality: { greater_than_or_equal_to: 0 }
  validate :tax_details_per_receipt_within_limit, on: :create

  # --- Optional: presence constraints (if you want stricter control) ---
  # validates :rate, presence: true
  # validates :amount, presence: true
  # validates :net_amount, presence: true

  private

  def tax_details_per_receipt_within_limit
    return if receipt.blank?
    return if sibling_count_for_limit(:receipt_tax_details) < MAX_PER_RECEIPT

    errors.add(:receipt, :receipt_tax_details_limit_exceeded, limit: MAX_PER_RECEIPT)
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
