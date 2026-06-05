class ReceiptAdjustment < ApplicationRecord
  DEFAULT_MAX_PER_RECEIPT = 50
  MAX_PER_RECEIPT = DEFAULT_MAX_PER_RECEIPT

  KINDS = %w[
    receipt_discount
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

  SURCHARGE_KINDS = %w[
    service_charge
    late_night_charge
    delivery_fee
    bag_fee
    handling_fee
  ].freeze

  DISCOUNT_KINDS = %w[
    receipt_discount
    coupon
    point_usage
    return_refund
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
  validate :adjustments_per_receipt_within_limit, on: :create

  def discount?
    sign == "discount"
  end

  def surcharge?
    sign == "surcharge"
  end

  def signed_amount
    surcharge? ? amount.to_i : -amount.to_i
  end

  def self.kind_options(kinds = KINDS)
    kinds.map do |key|
      [ I18n.t("enums.receipt_adjustment.kind.#{key}", default: key), key ]
    end
  end

  def self.sign_options
    SIGNS.map do |key|
      [ I18n.t("enums.receipt_adjustment.sign.#{key}", default: key), key ]
    end
  end

  def self.default_sign_for(kind)
    SURCHARGE_KINDS.include?(kind.to_s) ? "surcharge" : "discount"
  end

  def self.per_receipt_limit
    SystemSettings.limit_for("limits.receipt_adjustments_per_receipt")
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
    DEFAULT_MAX_PER_RECEIPT
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

  def adjustments_per_receipt_within_limit
    return if receipt.blank?
    limit = self.class.per_receipt_limit
    return if sibling_count_for_limit(:receipt_adjustments) < limit

    errors.add(:receipt, :receipt_adjustments_limit_exceeded, limit: limit)
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
