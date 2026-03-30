class Receipt < ApplicationRecord
  PAYMENT_METHODS = %w[
    cash
    credit_card
    e_money
    qr_payment
    debit_card
    other
  ].freeze

  belongs_to :user
  has_many :receipt_items, dependent: :destroy
  has_one_attached :image

  accepts_nested_attributes_for :receipt_items, allow_destroy: false

  def self.payment_method_options
    PAYMENT_METHODS.map do |key|
      [ I18n.t("enums.receipt.payment_method.#{key}"), key ]
    end
  end

  def payment_method_label
    I18n.t("enums.receipt.payment_method.#{payment_method}")
  end
end
