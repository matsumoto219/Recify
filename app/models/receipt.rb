class Receipt < ApplicationRecord
  PAYMENT_METHODS = %w[
    cash
    credit_card
    e_money
    qr_payment
    debit_card
    other
  ].freeze

  enum :payment_method, PAYMENT_METHODS.index_with { |v| v }

  enum :status, {
    uploaded: "uploaded",
    processing: "processing",
    review_needed: "review_needed",
    completed: "completed",
    failed: "failed"
  }

  belongs_to :user
  has_many :receipt_items, dependent: :destroy
  has_one_attached :image

  accepts_nested_attributes_for :receipt_items, allow_destroy: false

  validates :payment_method, inclusion: { in: PAYMENT_METHODS }, allow_blank: true
  validates :status, inclusion: { in: statuses.keys }, allow_blank: true

  def self.payment_method_options
    PAYMENT_METHODS.map do |key|
      [ I18n.t("enums.receipt.payment_method.#{key}"), key ]
    end
  end

  def payment_method_label
    return "" if payment_method.blank?

    I18n.t("enums.receipt.payment_method.#{payment_method}", default: payment_method)
  end

  def status_label
    return "" if status.blank?

    I18n.t("enums.receipt.status.#{status}", default: status)
  end
end
