class ReceiptAdjustment < ApplicationRecord
  KINDS = %w[
    receipt_discount
    item_discount
    coupon
    point_usage
    return_refund
    service_charge
    late_night_charge
    delivery_fee
    bag_fee
    handling_fee
    other
  ].freeze

  SIGNS = %w[
    discount
    surcharge
  ].freeze

  SOURCES = %w[
    ai
    ocr
    manual
  ].freeze

  belongs_to :receipt

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :sign, presence: true, inclusion: { in: SIGNS }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :amount,
            presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 999_999_999 }
  validates :tax_rate,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
            allow_nil: true
  validates :confidence,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
            allow_nil: true
  validates :position_index,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 9_999 },
            allow_nil: true
  validate :review_reasons_must_be_array

  def discount?
    sign == "discount"
  end

  def surcharge?
    sign == "surcharge"
  end

  def signed_amount
    surcharge? ? amount.to_i : -amount.to_i
  end

  def kind_label
    I18n.t("enums.receipt_adjustment.kind.#{kind}", default: kind)
  end

  def sign_label
    I18n.t("enums.receipt_adjustment.sign.#{sign}", default: sign)
  end

  def review_reason_labels
    Array(review_reasons).map do |code|
      I18n.t("enums.receipt_adjustment.review_reason.#{code}", default: code)
    end
  end

  private

  def review_reasons_must_be_array
    return if review_reasons.is_a?(Array)

    errors.add(:review_reasons, :invalid)
  end
end
