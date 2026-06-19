class ReceiptItem < ApplicationRecord
  CATEGORIES = %w[
    food
    drink
    daily_goods
    household
    medical
    beauty
    transportation
    hobby
    other
  ].freeze

  COUNTABLE_QUANTITY_UNITS = %w[
    個
    点
    本
    袋
    枚
    台
    箱
    セット
  ].freeze

  MEASUREMENT_QUANTITY_UNITS = %w[
    kg
    g
    mg
    L
    ml
    cc
  ].freeze

  INTEGER_QUANTITY_UNITS = [
    *COUNTABLE_QUANTITY_UNITS,
    "その他"
  ].freeze

  DECIMAL_QUANTITY_UNITS = MEASUREMENT_QUANTITY_UNITS

  QUANTITY_UNITS = [
    *COUNTABLE_QUANTITY_UNITS,
    *MEASUREMENT_QUANTITY_UNITS,
    "その他"
  ].freeze

  DEFAULT_QUANTITY_UNIT = "個"

  belongs_to :receipt

  attribute :quantity_unit_code, :string, default: -> { ReceiptQuantityUnit.default_code }

  before_validation :sync_legacy_quantity_unit_from_code

  scope :needs_review_only, -> { where(needs_review: true) }

  validates :category, inclusion: { in: CATEGORIES }, allow_blank: true

  # 数値の最低値を0以上に
  validates :price,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: ->(_item) { ReceiptAmountLimits.receipt_item_price_max }
            },
            allow_blank: true
  validates :line_total,
            :original_line_total,
            :discount_amount,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: ->(_item) { ReceiptAmountLimits.receipt_item_line_total_max }
            },
            allow_blank: true

  validates :quantity,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 9_999.999 },
            allow_blank: true
  validate :quantity_must_be_integer_for_integer_unit

  validates :position_index,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 9_999 },
            allow_blank: true

  validates :needs_review,
            inclusion: { in: [ true, false ] },
            allow_nil: true

  # 税率（0.0〜1.0で保存）
  validates :tax_rate,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
            allow_nil: true

  validates :discount_rate,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
            allow_nil: true

  # 文字列項目の最大文字数
  validates :raw_text, length: { maximum: 1000 }, allow_blank: true       # OCR原文テキスト(MAX1000文字)
  validates :suggested_name, length: { maximum: 500 }, allow_blank: true  # AI補完候補名(MAX500文字)
  validates :confirmed_name, length: { maximum: 500 }, allow_blank: true  # ユーザー確定名(MAX500文字)
  validates :quantity_unit, length: { maximum: 50 }, allow_blank: true    # 数量単位(MAX50文字)
  validates :quantity_unit_code,
            presence: true,
            inclusion: { in: ->(_item) { ReceiptQuantityUnit.allowed_codes } }
  validates :product_code, length: { maximum: 100 }, allow_blank: true    # 商品コード(MAX100文字)

  # AI関連(信頼度 0.0~1.0)
  validates :confidence,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
            allow_blank: true
  validate :items_per_receipt_within_limit, on: :create

  def review_required?
    needs_review?
  end

  def self.category_options
    CATEGORIES.map do |key|
      [ I18n.t("enums.receipt_item.category.#{key}"), key ]
    end
  end

  def self.quantity_unit_options
    ReceiptQuantityUnit.options
  end

  def self.decimal_quantity_unit?(unit)
    ReceiptQuantityUnit.decimal?(unit)
  end

  def self.integer_quantity_unit?(unit)
    !decimal_quantity_unit?(unit)
  end

  def self.quantity_step_for(unit)
    decimal_quantity_unit?(unit) ? "0.001" : "1"
  end

  def self.quantity_inputmode_for(unit)
    decimal_quantity_unit?(unit) ? "decimal" : "numeric"
  end

  def category_label
    return "" if category.blank?

    I18n.t("enums.receipt_item.category.#{category}", default: category)
  end

  def review_reason_labels
    Array(review_reasons).map do |code|
      I18n.t("enums.receipt_item.review_reason.#{code}", default: code)
    end
  end

  def quantity_unit_label
    ReceiptQuantityUnit.label(normalized_quantity_unit_code)
  end

  def normalized_quantity_unit_code
    legacy_code = ReceiptQuantityUnit.normalize(quantity_unit, default: nil)
    code = quantity_unit_code.presence

    return code if code.present? && (code != ReceiptQuantityUnit.default_code || legacy_code.blank?)

    legacy_code.presence || code.presence || ReceiptQuantityUnit.default_code
  end

  def formatted_quantity
    value = quantity.presence || BigDecimal("1")
    decimal = BigDecimal(value.to_s)

    return decimal.to_i.to_s if decimal.frac.zero?

    format("%.3f", decimal)
  end

  def formatted_quantity_for_input
    return nil if quantity.blank?

    decimal = BigDecimal(quantity.to_s)

    return decimal.to_i.to_s if decimal.frac.zero?

    decimal.to_s("F").sub(/\.?0+\z/, "")
  end

  def discount_rate_percentage_input
    rate = discount_rate.presence || inferred_discount_rate
    return nil if rate.blank?

    percentage = BigDecimal(rate.to_s) * 100
    return percentage.to_i.to_s if percentage.frac.zero?

    percentage.to_s("F").sub(/\.?0+\z/, "")
  end

  def formatted_quantity_with_unit
    "#{formatted_quantity} #{quantity_unit_label}"
  end

  private

  def quantity_must_be_integer_for_integer_unit
    return if quantity.blank?
    return if self.class.decimal_quantity_unit?(normalized_quantity_unit_code)

    decimal = BigDecimal(quantity.to_s)
    errors.add(:quantity, :must_be_integer_for_unit) unless decimal.frac.zero?
  rescue ArgumentError
    nil
  end

  def sync_legacy_quantity_unit_from_code
    return unless has_attribute?(:quantity_unit)
    return if quantity_unit_code.blank?
    return unless ReceiptQuantityUnit.allowed_codes.include?(quantity_unit_code)

    legacy_code = ReceiptQuantityUnit.normalize(quantity_unit, default: nil)
    if legacy_code.present? &&
       quantity_unit_code == ReceiptQuantityUnit.default_code &&
       !will_save_change_to_quantity_unit_code?
      return
    end

    self.quantity_unit = ReceiptQuantityUnit.legacy_label(quantity_unit_code)
  end

  def inferred_discount_rate
    discount = discount_amount.to_i
    original_total = original_line_total.to_i
    return nil unless discount.positive?
    return nil unless original_total.positive?
    return nil if discount > original_total

    BigDecimal(discount.to_s) / BigDecimal(original_total.to_s)
  end

  def items_per_receipt_within_limit
    return if receipt.blank?
    return if sibling_count_for_limit(:receipt_items) < receipt.receipt_items_limit

    errors.add(:receipt, :receipt_items_limit_exceeded, limit: receipt.receipt_items_limit)
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
