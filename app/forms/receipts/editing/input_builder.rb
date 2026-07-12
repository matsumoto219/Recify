# frozen_string_literal: true

class Receipts::Editing::InputBuilder
  class ConflictError < StandardError
    attr_reader :attributes_key, :duplicate_ids

    def initialize(attributes_key:, duplicate_ids:)
      @attributes_key = attributes_key
      @duplicate_ids = duplicate_ids
      super("Duplicate nested child ids for #{attributes_key}")
    end
  end

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

      raise ConflictError.new(attributes_key: attributes_key, duplicate_ids: duplicate_ids)
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
      apply_item_input_presence!(merged, attributes) if association_name == :receipt_items
      merged
    end

    unsubmitted_records = existing_records.filter_map do |record|
      next if referenced_ids.include?(record.id.to_s)

      serialized = serialized_record(record, fields)
      apply_item_input_presence!(serialized, {}) if association_name == :receipt_items
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

  def apply_item_input_presence!(item, submitted_attributes)
    item["amount_discount_amount_present"] =
      if submitted_attributes.key?("discount_rate")
        false
      else
        item["discount_amount"].present?
      end
  end
end
