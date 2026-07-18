# frozen_string_literal: true

class Receipts::Editing::InputBuilder
  Result = Data.define(:receipt_items, :receipt_adjustments, :receipt_payments)
  NESTED_ATTRIBUTE_KEYS = %w[
    receipt_items_attributes
    receipt_adjustments_attributes
    receipt_payments_attributes
  ].freeze

  ITEM_FIELDS = %i[
    id
    confirmed_name
    category
    price
    quantity
    quantity_unit_code
    product_code
    tax_rate
    discount_rate
    discount_amount
    original_line_total
    line_total
    position_index
    needs_review
    review_reasons
  ].freeze
  ADJUSTMENT_FIELDS = %i[
    id
    kind
    label
    amount
    sign
    effect
    tax_rate
    position_index
    needs_review
    review_reasons
    source
    source_provider
    source_field_path
    source_line_index
    source_span_start
    source_span_end
  ].freeze
  PAYMENT_FIELDS = %i[
    id
    method
    amount
    source_provider
    source_field_path
    source_line_index
    source_span_start
    source_span_end
  ].freeze
  ITEM_SOURCE_FIELDS = %w[price quantity quantity_unit_code discount_rate discount_amount].freeze

  def self.call(receipt:, permitted:)
    new(receipt: receipt, permitted: permitted).call
  end

  def initialize(receipt:, permitted:)
    @receipt = receipt
    @permitted = permitted
  end

  def call
    validate_unique_child_ids!

    Result.new(
      receipt_items: merged_collection(:receipt_items, "receipt_items_attributes", ITEM_FIELDS),
      receipt_adjustments: merged_collection(:receipt_adjustments, "receipt_adjustments_attributes", ADJUSTMENT_FIELDS),
      receipt_payments: merged_collection(:receipt_payments, "receipt_payments_attributes", PAYMENT_FIELDS)
    )
  end

  private

  def validate_unique_child_ids!
    NESTED_ATTRIBUTE_KEYS.each do |attributes_key|
      ids = submitted_attributes(attributes_key).filter_map { |attributes| attributes["id"].to_s.presence }
      duplicate_ids = ids.tally.select { |_id, count| count > 1 }.keys
      next if duplicate_ids.empty?

      raise Receipts::Editing::ConflictError.new(attributes_key: attributes_key, duplicate_ids: duplicate_ids)
    end
  end

  def merged_collection(association_name, attributes_key, fields)
    existing_records = @receipt.public_send(association_name).to_a
    existing_by_id = existing_records.index_by { |record| record.id.to_s }
    submitted = submitted_attributes(attributes_key)
    referenced_ids = Set.new

    submitted_records = submitted.filter_map do |attributes|
      id = attributes["id"].to_s.presence
      referenced_ids << id if id
      next if destroyed?(attributes)

      existing = id && existing_by_id[id]
      merged = serialized_record(existing, fields).merge(attributes.except("_destroy"))
      apply_item_input_presence!(merged, attributes, existing) if association_name == :receipt_items
      merged
    end

    unsubmitted_records = existing_records.filter_map do |record|
      next if referenced_ids.include?(record.id.to_s)

      serialized = serialized_record(record, fields)
      apply_item_input_presence!(serialized, {}, record) if association_name == :receipt_items
      serialized
    end

    submitted_records + unsubmitted_records
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

  def serialized_record(record, fields)
    return {} if record.nil?

    fields.each_with_object({}) do |field, result|
      result[field.to_s] = record.public_send(field) if record.respond_to?(field)
    end
  end

  def destroyed?(attributes)
    ActiveModel::Type::Boolean.new.cast(attributes["_destroy"])
  end

  def apply_item_input_presence!(item, submitted_attributes, existing)
    %w[price quantity line_total].each do |field|
      item["amount_#{field}_present"] = submitted_attributes.key?(field) && submitted_attributes[field].present?
    end
    item["amount_countable_source_changed"] = ITEM_SOURCE_FIELDS.any? do |field|
      submitted_item_field_changed?(existing, submitted_attributes, field)
    end
    item["amount_line_total_changed"] = submitted_item_field_changed?(existing, submitted_attributes, "line_total")
    apply_persisted_item_amounts!(item, existing) if existing
    item["amount_discount_amount_present"] =
      if submitted_attributes.key?("discount_rate")
        false
      else
        item["discount_amount"].present?
      end
  end

  def submitted_item_field_changed?(existing, submitted_attributes, field)
    return false unless submitted_attributes.key?(field)
    return true unless existing

    comparable_item_value(field, existing.public_send(field)) != comparable_item_value(field, submitted_attributes[field])
  end

  def comparable_item_value(field, value)
    case field
    when "price", "line_total", "discount_amount"
      value.blank? ? nil : value.to_i
    when "quantity"
      value.blank? ? nil : BigDecimal(value.to_s)
    when "discount_rate"
      return nil if value.blank?

      rate = BigDecimal(value.to_s.delete("%"))
      rate > 1 ? rate / 100 : rate
    when "quantity_unit_code"
      value.to_s
    end
  rescue ArgumentError
    value
  end

  def apply_persisted_item_amounts!(item, existing)
    item["amount_persisted_item"] = true
    item["amount_persisted_original_line_total"] = existing.original_line_total
    item["amount_persisted_discount_amount"] = existing.discount_amount
    item["amount_persisted_discount_rate"] = existing.discount_rate
    item["amount_persisted_line_total"] = existing.line_total
  end
end
