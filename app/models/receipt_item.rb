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

  PRICING_SOURCE_KINDS = %w[
    count_unit_price
    explicit_line_total
    reference_quantity_price
  ].freeze
  REFERENCE_PRICE_AMOUNT_MAX = BigDecimal("999999999999")
  REFERENCE_PRICE_AMOUNT_MAX_SCALE = 6
  REFERENCE_QUANTITY_MAX = BigDecimal("9999.999")
  REFERENCE_QUANTITY_MAX_SCALE = 3
  RAW_UNIT_MAX_LENGTH = 64

  belongs_to :receipt

  attribute :quantity_unit_code, :string, default: -> { ReceiptQuantityUnit.default_code }

  scope :needs_review_only, -> { where(needs_review: true) }

  validates :category, inclusion: { in: CATEGORIES }, allow_blank: true

  # 数値の最低値を0以上に
  validates :price,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: ->(_item) { ReceiptAmountService.receipt_item_price_max }
            },
            allow_blank: true
  validates :line_total,
            :original_line_total,
            :discount_amount,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: ->(_item) { ReceiptAmountService.receipt_item_line_total_max }
            },
            allow_blank: true

  validates :quantity,
            numericality: { greater_than: 0, less_than_or_equal_to: 9_999.999 },
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
  validates :quantity_unit_code,
            presence: true,
            inclusion: { in: ->(_item) { ReceiptQuantityUnit.allowed_codes } }
  validates :pricing_source_kind,
            inclusion: { in: PRICING_SOURCE_KINDS },
            allow_nil: true
  validates :reference_quantity_unit_code,
            inclusion: { in: ->(_item) { ReceiptQuantityUnit.allowed_codes } },
            allow_nil: true
  validates :product_code, length: { maximum: 100 }, allow_blank: true    # 商品コード(MAX100文字)

  # AI関連(信頼度 0.0~1.0)
  validates :confidence,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
            allow_blank: true
  validate :items_per_receipt_within_limit, on: :create
  validate :measurement_pricing_source_contract

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
    return I18n.t("receipts.item_fields.uncategorized") unless CATEGORIES.include?(category)

    I18n.t("enums.receipt_item.category.#{category}")
  end

  def review_reason_labels
    ReviewReasons.review_reasons_for_user(review_reasons).map do |code|
      I18n.t("enums.receipt_item.review_reason.#{code}", default: code)
    end
  end

  def quantity_unit_label
    ReceiptQuantityUnit.label(normalized_quantity_unit_code)
  end

  def normalized_quantity_unit_code
    quantity_unit_code.presence || ReceiptQuantityUnit.default_code
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

  def measurement_pricing_source_contract
    validate_exact_reference_numeric(
      :reference_price_amount,
      minimum: BigDecimal("0"),
      maximum: REFERENCE_PRICE_AMOUNT_MAX,
      maximum_scale: REFERENCE_PRICE_AMOUNT_MAX_SCALE,
      minimum_inclusive: true
    )
    validate_exact_reference_numeric(
      :reference_quantity,
      minimum: BigDecimal("0"),
      maximum: REFERENCE_QUANTITY_MAX,
      maximum_scale: REFERENCE_QUANTITY_MAX_SCALE,
      minimum_inclusive: false
    )
    validate_reference_quantity_granularity
    validate_raw_unit_token(:quantity_unit_raw)
    validate_raw_unit_token(:reference_quantity_unit_raw)
    validate_reference_evidence_shape
    validate_pricing_source_integrity
  end

  def validate_exact_reference_numeric(attribute, minimum:, maximum:, maximum_scale:, minimum_inclusive:)
    raw_value = source_value_before_type_cast(attribute)
    return if raw_value.nil?

    exact_value = exact_decimal_rational(raw_value)
    valid_minimum = if exact_value
      minimum_inclusive ? exact_value >= minimum.to_r : exact_value > minimum.to_r
    end
    valid = exact_value &&
      valid_minimum &&
      exact_value <= maximum.to_r &&
      finite_decimal_scale(exact_value)&.<=(maximum_scale)

    errors.add(attribute, :invalid) unless valid
  end

  def validate_reference_quantity_granularity
    raw_quantity = source_value_before_type_cast(:reference_quantity)
    unit = ReceiptQuantityUnit.unit_for(reference_quantity_unit_code)
    return if raw_quantity.nil? || unit.nil?

    exact_quantity = exact_decimal_rational(raw_quantity)
    valid = exact_quantity&.positive? &&
      (exact_quantity / unit.input_granularity).denominator == 1
    errors.add(:reference_quantity, :invalid) unless valid
  end

  def validate_raw_unit_token(attribute)
    raw_value = source_value_before_type_cast(attribute)
    return if raw_value.nil?

    valid = raw_value.is_a?(String) &&
      raw_value.valid_encoding? &&
      raw_value.length.between?(1, RAW_UNIT_MAX_LENGTH) &&
      raw_value == raw_value.strip &&
      !raw_value.match?(/\p{Cc}/)

    errors.add(attribute, :invalid) unless valid
  end

  def validate_reference_evidence_shape
    return if reference_evidence_absent? || reference_evidence_canonical? || reference_evidence_raw?

    errors.add(:reference_price_amount, :invalid)
  end

  def validate_pricing_source_integrity
    valid = case pricing_source_kind
    when nil
      true
    when "count_unit_price"
      count_unit_price_source_valid?
    when "explicit_line_total"
      !line_total.nil?
    when "reference_quantity_price"
      reference_quantity_price_source_valid?
    else
      return
    end

    errors.add(:pricing_source_kind, :invalid) unless valid
  end

  def count_unit_price_source_valid?
    unit = ReceiptQuantityUnit.unit_for(quantity_unit_code)

    !price.nil? &&
      !quantity.nil? &&
      unit&.kind == :countable &&
      reference_evidence_absent? &&
      quantity_unit_raw.nil? &&
      reference_quantity_unit_raw.nil?
  end

  def reference_quantity_price_source_valid?
    purchased_unit = ReceiptQuantityUnit.unit_for(quantity_unit_code)
    reference_unit = ReceiptQuantityUnit.unit_for(reference_quantity_unit_code)

    !quantity.nil? &&
      !purchased_unit.nil? &&
      !reference_unit.nil? &&
      reference_evidence_canonical? &&
      quantity_unit_raw.nil? &&
      reference_quantity_unit_raw.nil? &&
      ReceiptQuantityUnit.convertible?(from: purchased_unit.code, to: reference_unit.code)
  end

  def reference_evidence_absent?
    reference_evidence_presence == [ false, false, false, false ]
  end

  def reference_evidence_canonical?
    reference_evidence_presence == [ true, true, true, false ]
  end

  def reference_evidence_raw?
    reference_evidence_presence == [ true, true, false, true ]
  end

  def reference_evidence_presence
    %i[
      reference_price_amount
      reference_quantity
      reference_quantity_unit_code
      reference_quantity_unit_raw
    ].map { |attribute| !source_value_before_type_cast(attribute).nil? }
  end

  def source_value_before_type_cast(attribute)
    read_attribute_before_type_cast(attribute)
  end

  def exact_decimal_rational(value)
    case value
    when Integer, Rational
      value.to_r
    when BigDecimal
      value.to_r if value.finite?
    when String
      Rational(value) if value.match?(/\A[+-]?\d+(?:\.\d+)?\z/)
    end
  rescue ArgumentError, TypeError, FloatDomainError, ZeroDivisionError
    nil
  end

  def finite_decimal_scale(value)
    denominator = value.denominator
    powers_of_two = factor_count(denominator, 2)
    denominator /= 2**powers_of_two
    powers_of_five = factor_count(denominator, 5)
    denominator /= 5**powers_of_five

    [ powers_of_two, powers_of_five ].max if denominator == 1
  end

  def factor_count(value, factor)
    count = 0
    while (value % factor).zero?
      count += 1
      value /= factor
    end
    count
  end

  def quantity_must_be_integer_for_integer_unit
    return if quantity.blank?
    return if self.class.decimal_quantity_unit?(normalized_quantity_unit_code)

    decimal = BigDecimal(quantity.to_s)
    errors.add(:quantity, :must_be_integer_for_unit) unless decimal.frac.zero?
  rescue ArgumentError
    nil
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
