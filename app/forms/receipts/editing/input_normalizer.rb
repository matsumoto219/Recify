# frozen_string_literal: true

class Receipts::Editing::InputNormalizer
  RECEIPT_INTEGER_FIELDS = %w[total_amount subtotal_amount tax_amount].freeze
  RECEIPT_DECIMAL_FIELDS = %w[tax_rate].freeze
  ITEM_INTEGER_FIELDS = %w[price line_total].freeze
  ITEM_QUANTITY_FIELDS = %w[quantity].freeze
  ITEM_PERCENTAGE_FIELDS = %w[tax_rate].freeze
  ITEM_DISCOUNT_FIELDS = %w[discount_rate].freeze
  ADJUSTMENT_REVIEW_TARGET_FIELDS = %i[kind label amount sign tax_rate].freeze

  def self.call(receipt:, attributes:)
    new(receipt: receipt, attributes: attributes).call
  end

  def initialize(receipt:, attributes:)
    @receipt = receipt
    @attributes = attributes.to_h.deep_dup
  end

  def call
    normalize_purchased_at!
    normalize_numeric_inputs!
    normalize_item_quantity_units!
    normalize_adjustments!
    attributes
  end

  private

  attr_reader :receipt, :attributes

  def normalize_purchased_at!
    submitted = attributes.key?("purchased_on") || attributes.key?("purchased_time")
    purchased_on = attributes.delete("purchased_on")
    purchased_time = attributes.delete("purchased_time")

    attributes["purchased_at"] = build_purchased_at(purchased_on, purchased_time) if submitted
  end

  def build_purchased_at(purchased_on, purchased_time)
    return if purchased_on.blank?

    datetime_text = [ purchased_on, purchased_time.presence ].compact.join(" ")
    Time.zone.parse(datetime_text)
  rescue ArgumentError, TypeError
    nil
  end

  def normalize_numeric_inputs!
    normalize_numeric_fields!(attributes, RECEIPT_INTEGER_FIELDS, :integer)
    normalize_numeric_fields!(attributes, RECEIPT_DECIMAL_FIELDS, :decimal)

    attributes["receipt_items_attributes"]&.each_value do |item_attributes|
      normalize_numeric_fields!(item_attributes, ITEM_INTEGER_FIELDS, :integer)
      normalize_numeric_fields!(item_attributes, ITEM_QUANTITY_FIELDS, :decimal)
      normalize_numeric_fields!(item_attributes, ITEM_PERCENTAGE_FIELDS, :percentage)
      normalize_numeric_fields!(item_attributes, ITEM_DISCOUNT_FIELDS, :decimal)
    end

    attributes["receipt_adjustments_attributes"]&.each_value do |adjustment_attributes|
      normalize_numeric_fields!(adjustment_attributes, %w[amount], :integer)
      normalize_numeric_fields!(adjustment_attributes, %w[tax_rate], :percentage)
    end

    attributes["receipt_payments_attributes"]&.each_value do |payment_attributes|
      normalize_numeric_fields!(payment_attributes, %w[amount], :integer)
    end
  end

  def normalize_numeric_fields!(target, fields, parser)
    fields.each do |field|
      next unless target.key?(field)

      target[field] = Receipts::NumericInput.public_send(parser, target[field])
    end
  end

  def normalize_item_quantity_units!
    item_attributes = attributes["receipt_items_attributes"]
    return if item_attributes.blank?

    item_attributes.each_value do |item|
      raw_code = item["quantity_unit_code"]
      code = if raw_code.blank?
        ReceiptQuantityUnit.default_code
      else
        ReceiptQuantityUnit.normalize(raw_code, default: nil)
      end

      item["quantity_unit_code"] = code || raw_code.to_s
    end
  end

  def normalize_adjustments!
    adjustment_attributes = attributes["receipt_adjustments_attributes"]
    return if adjustment_attributes.blank?

    existing_adjustments = receipt&.receipt_adjustments&.index_by { |adjustment| adjustment.id.to_s } || {}

    adjustment_attributes.each_value do |adjustment|
      adjustment["kind"] = ReceiptAdjustment.normalize_kind(adjustment["kind"])
      adjustment["sign"] = normalized_adjustment_sign(
        kind: adjustment["kind"],
        requested_sign: adjustment["sign"]
      )

      existing = existing_adjustments[adjustment["id"].to_s]
      next if existing && !adjustment_review_target_changed?(existing, adjustment)

      adjustment["source"] = "manual"
      adjustment["needs_review"] = false
      adjustment["review_reasons"] = []
    end
  end

  def adjustment_review_target_changed?(adjustment, submitted)
    changed_adjustment = adjustment.dup
    changed_adjustment.assign_attributes(submitted.slice(*ADJUSTMENT_REVIEW_TARGET_FIELDS.map(&:to_s)))

    ADJUSTMENT_REVIEW_TARGET_FIELDS.any? do |field|
      submitted.key?(field.to_s) && changed_adjustment.public_send(field) != adjustment.public_send(field)
    end
  end

  def normalized_adjustment_sign(kind:, requested_sign:)
    kind = kind.to_s
    requested_sign = requested_sign.to_s

    if kind == "other"
      return requested_sign if ReceiptAdjustment::SIGNS.include?(requested_sign)

      return "surcharge"
    end

    ReceiptAdjustment.default_sign_for(kind)
  end
end
