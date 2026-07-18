# frozen_string_literal: true

class Receipts::Editing::ChangeSet
  Result = Data.define(
    :item_amounts_changed,
    :purchase_adjustments_changed,
    :payment_adjustments_changed,
    :payments_changed,
    :receipt_amounts_changed
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
  end

  ITEM_AMOUNT_FIELDS = %w[
    price
    quantity
    quantity_unit_code
    tax_rate
    discount_rate
  ].freeze
  ADJUSTMENT_AMOUNT_FIELDS = %w[
    kind
    label
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

  def self.call(receipt:, permitted:)
    new(receipt: receipt, permitted: permitted).call
  end

  def initialize(receipt:, permitted:)
    @receipt = receipt
    @permitted = permitted
  end

  def call
    purchase_adjustments_changed, payment_adjustments_changed = adjustment_changes

    Result.new(
      item_amounts_changed: item_amounts_changed?,
      purchase_adjustments_changed: purchase_adjustments_changed,
      payment_adjustments_changed: payment_adjustments_changed,
      payments_changed: collection_changed?(
        :receipt_payments,
        "receipt_payments_attributes",
        PAYMENT_FIELDS
      ),
      receipt_amounts_changed: record_changed?(@receipt, @permitted, RECEIPT_AMOUNT_FIELDS)
    )
  end

  private

  def item_amounts_changed?
    submitted_attributes("receipt_items_attributes").any? do |attributes|
      record = existing_record(:receipt_items, attributes["id"])
      next record.present? if destroyed?(attributes)
      next true if record.nil?

      record_changed?(record, attributes, ITEM_AMOUNT_FIELDS) || item_line_total_source_changed?(record, attributes)
    end
  end

  def item_line_total_source_changed?(record, attributes)
    return false unless attributes.key?("line_total")

    quantity_unit_code = attributes.fetch("quantity_unit_code", record.quantity_unit_code)
    price = attributes.fetch("price", record.price)
    return false if ReceiptQuantityUnit.countable?(quantity_unit_code) && price.present?

    record_changed?(record, attributes, %w[line_total])
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
      changed = destroyed?(attributes) ? record.present? : record.nil? || record_changed?(record, attributes, ADJUSTMENT_AMOUNT_FIELDS)
      next unless changed

      effects = []
      effects << ReceiptAmountService.adjustment_effect(record) if record
      effects << ReceiptAmountService.adjustment_effect(merged_record(record, attributes)) unless destroyed?(attributes)

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
