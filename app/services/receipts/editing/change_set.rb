# frozen_string_literal: true

class Receipts::Editing::ChangeSet
  Result = Data.define(
    :item_amounts_changed,
    :purchase_adjustments_changed,
    :payment_adjustments_changed,
    :payments_changed,
    :receipt_amounts_changed,
    :amount_inputs_submitted
  ) do
    def derived_purchase_inputs_changed?
      item_amounts_changed || purchase_adjustments_changed
    end

    def purchase_amounts_changed?
      derived_purchase_inputs_changed? || receipt_amounts_changed
    end

    def payment_reconciliation_changed?
      payments_changed || payment_adjustments_changed || purchase_amounts_changed?
    end

    def amount_related_changed?
      purchase_amounts_changed? || payment_adjustments_changed || payments_changed
    end

    def amount_inputs_submitted?
      amount_inputs_submitted == true
    end
  end

  ITEM_AMOUNT_FIELDS = %w[
    price
    quantity
    quantity_unit_code
    tax_rate
    discount_rate
  ].freeze
  ITEM_NON_AMOUNT_FIELDS = %w[
    confirmed_name
    category
    product_code
    position_index
  ].freeze
  ADJUSTMENT_AMOUNT_FIELDS = %w[
    kind
    amount
    sign
    tax_rate
  ].freeze
  PAYMENT_FIELDS = %w[
    method
    amount
  ].freeze
  RECEIPT_AMOUNT_FIELDS = %w[
    subtotal_amount
    tax_amount
    total_amount
    tax_rate
  ].freeze
  ITEM_AMOUNT_INPUT_FIELDS = (ITEM_AMOUNT_FIELDS + %w[discount_amount line_total _destroy]).freeze
  ITEM_MONETARY_SOURCE_FIELDS = %w[price original_line_total line_total discount_amount].freeze
  ADJUSTMENT_AMOUNT_INPUT_FIELDS = (ADJUSTMENT_AMOUNT_FIELDS + %w[_destroy]).freeze
  PAYMENT_INPUT_FIELDS = (PAYMENT_FIELDS + %w[_destroy]).freeze

  def self.call(receipt:, permitted:)
    new(receipt: receipt, permitted: permitted).call
  end

  def initialize(receipt:, permitted:)
    @receipt = receipt
    @permitted = permitted
  end

  def call
    purchase_adjustments_changed, payment_adjustments_changed = adjustment_changes
    item_amounts_changed = item_amounts_changed?
    payments_changed = collection_changed?(
      :receipt_payments,
      "receipt_payments_attributes",
      PAYMENT_FIELDS
    )
    receipt_amounts_changed = record_changed?(@receipt, @permitted, RECEIPT_AMOUNT_FIELDS)
    amount_related_changed = item_amounts_changed ||
      purchase_adjustments_changed ||
      payment_adjustments_changed ||
      payments_changed ||
      receipt_amounts_changed

    Result.new(
      item_amounts_changed: item_amounts_changed,
      purchase_adjustments_changed: purchase_adjustments_changed,
      payment_adjustments_changed: payment_adjustments_changed,
      payments_changed: payments_changed,
      receipt_amounts_changed: receipt_amounts_changed,
      amount_inputs_submitted: amount_related_changed || unchanged_nested_amount_confirmation_submitted?
    )
  end

  private

  def item_amounts_changed?
    submitted_attributes("receipt_items_attributes").any? do |attributes|
      record = existing_record(:receipt_items, attributes["id"])
      next item_monetary_source_present?(record) if destroyed?(attributes)

      changed_record = merged_item(record, attributes)
      next item_monetary_source_present?(changed_record) if record.nil?

      changed = record_changed?(record, attributes, ITEM_AMOUNT_FIELDS) ||
        item_line_total_source_changed?(record, attributes)
      changed && (item_monetary_source_present?(record) || item_monetary_source_present?(changed_record))
    end
  end

  def merged_item(record, attributes)
    changed_record = record ? record.dup : ReceiptItem.new
    changed_record.assign_attributes(attributes.slice(*(ITEM_AMOUNT_FIELDS + ITEM_MONETARY_SOURCE_FIELDS)))
    changed_record
  end

  def item_monetary_source_present?(record)
    return false unless record

    value_present?(record.price) ||
      value_present?(record.line_total) ||
      record.original_line_total.to_i.positive? ||
      record.discount_amount.to_i.positive?
  end

  def value_present?(value)
    !value.nil? && value.to_s.strip != ""
  end

  def item_line_total_source_changed?(record, attributes)
    return false unless attributes.key?("line_total")

    quantity_unit_code = attributes.fetch("quantity_unit_code", record.quantity_unit_code)
    price = attributes.fetch("price", record.price)
    if ReceiptQuantityUnit.countable?(quantity_unit_code) && price.present?
      return unexplained_countable_total?(record, attributes)
    end

    record_changed?(record, attributes, %w[line_total])
  end

  def unexplained_countable_total?(record, attributes)
    changed_record = record.dup
    changed_record.assign_attributes(attributes.slice(*ITEM_AMOUNT_FIELDS, "line_total"))
    expected_line_total = (
      BigDecimal(changed_record.price.to_s) * BigDecimal(changed_record.quantity.to_s)
    ).round(0).to_i
    return false if record.line_total.to_i == expected_line_total
    return true unless record.original_line_total.to_i == expected_line_total
    return false if record.discount_rate.present? || record.discount_amount.present?

    record.line_total.to_i < expected_line_total
  rescue ArgumentError
    false
  end

  def collection_changed?(association_name, attributes_key, fields)
    submitted_attributes(attributes_key).any? do |attributes|
      record = existing_record(association_name, attributes["id"])
      next record.present? if destroyed?(attributes)
      next true if record.nil?

      record_changed?(record, attributes, fields)
    end
  end

  def adjustment_changes
    purchase_changed = false
    payment_changed = false

    submitted_attributes("receipt_adjustments_attributes").each do |attributes|
      record = existing_record(:receipt_adjustments, attributes["id"])
      effects = []
      effects << ReceiptAmountService.adjustment_effect(record) if record
      effects << ReceiptAmountService.adjustment_effect(merged_record(record, attributes)) unless destroyed?(attributes)
      changed =
        if destroyed?(attributes)
          record.present?
        else
          record.nil? ||
            record_changed?(record, attributes, ADJUSTMENT_AMOUNT_FIELDS) ||
            effects.uniq.many?
        end
      next unless changed

      payment_changed ||= effects.include?("payment_adjustment")
      purchase_changed ||= effects.any? { |effect| effect != "payment_adjustment" }
    end

    [ purchase_changed, payment_changed ]
  end

  def record_changed?(record, attributes, fields)
    comparable_attributes = attributes.slice(*fields)
    return false if comparable_attributes.empty?

    changed_record = record.dup
    changed_record.assign_attributes(comparable_attributes)

    fields.any? do |field|
      comparable_attributes.key?(field) && changed_record.public_send(field) != record.public_send(field)
    end
  end

  def unchanged_nested_amount_confirmation_submitted?
    return false if item_non_amount_fields_changed?

    collection_input_submitted?("receipt_items_attributes", ITEM_AMOUNT_INPUT_FIELDS) ||
      collection_input_submitted?("receipt_adjustments_attributes", ADJUSTMENT_AMOUNT_INPUT_FIELDS) ||
      collection_input_submitted?("receipt_payments_attributes", PAYMENT_INPUT_FIELDS)
  end

  def item_non_amount_fields_changed?
    submitted_attributes("receipt_items_attributes").any? do |attributes|
      record = existing_record(:receipt_items, attributes["id"])
      next false unless record

      record_changed?(record, attributes, ITEM_NON_AMOUNT_FIELDS)
    end
  end

  def collection_input_submitted?(key, fields)
    submitted_attributes(key).any? do |attributes|
      fields.any? { |field| attributes.key?(field) }
    end
  end

  def merged_record(record, attributes)
    changed_record = record ? record.dup : ReceiptAdjustment.new
    changed_record.assign_attributes(attributes.slice(*ADJUSTMENT_AMOUNT_FIELDS, "label", "source", "needs_review"))
    changed_record
  end

  def existing_record(association_name, id)
    return nil if id.blank?

    @receipt.public_send(association_name).find { |record| record.id.to_s == id.to_s }
  end

  def submitted_attributes(key)
    value = @permitted[key]
    return [] if value.blank?

    collection = value.respond_to?(:values) ? value.values : Array(value)
    collection.filter_map do |attributes|
      next unless attributes.respond_to?(:to_h)

      attributes.to_h.stringify_keys
    end
  end

  def destroyed?(attributes)
    ActiveModel::Type::Boolean.new.cast(attributes["_destroy"])
  end
end
