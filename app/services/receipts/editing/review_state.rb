# frozen_string_literal: true

class Receipts::Editing::ReviewState
  Result = Data.define(:review_reasons, :status)
  ItemResult = Data.define(:review_reasons, :needs_review)
  ITEM_REVIEW_FIELD_RULES = {
    "item_name_uncertain" => %w[confirmed_name],
    "item_category_uncertain" => %w[category],
    "item_quantity_uncertain" => %w[quantity quantity_unit_code],
    "item_tax_rate_uncertain" => %w[tax_rate]
  }.freeze
  ITEM_DECIMAL_FIELDS = %w[quantity tax_rate].freeze

  FIELD_REVIEW_RULES = {
    store_name: {
      missing: "store_name_missing",
      resolved: %w[store_name_missing store_name_uncertain]
    },
    purchased_at: {
      missing: "purchased_at_missing",
      resolved: %w[purchased_at_missing purchased_at_uncertain purchased_at_conflicted]
    },
    payment_method: {
      missing: "payment_method_missing",
      resolved: %w[payment_method_missing payment_method_uncertain]
    }
  }.freeze

  class << self
    def call(receipt:, permitted:, amount_result:, consistency_review_reasons:, child_review_remaining:, nested_amount_inputs_submitted:, item_inputs_submitted:)
      new(
        receipt: receipt,
        permitted: permitted,
        amount_result: amount_result,
        consistency_review_reasons: consistency_review_reasons,
        child_review_remaining: child_review_remaining,
        nested_amount_inputs_submitted: nested_amount_inputs_submitted,
        item_inputs_submitted: item_inputs_submitted
      ).call
    end

    def item_review_state(item:, submitted_attributes:)
      reasons = Array(item.review_reasons).map(&:to_s)
      resolved_reasons = reasons.select do |reason|
        item_review_reason_resolved?(reason, item: item, submitted_attributes: submitted_attributes)
      end
      remaining_reasons = reasons - resolved_reasons
      needs_review = remaining_reasons.present? || (item.needs_review? && resolved_reasons.empty?)

      ItemResult.new(review_reasons: remaining_reasons, needs_review: needs_review)
    end

    def resolved_item_review_reasons(receipt:, permitted:)
      attributes = submitted_item_attributes(permitted)
      existing_items = receipt.receipt_items.index_by { |item| item.id.to_s }

      ITEM_REVIEW_FIELD_RULES.keys.select do |reason|
        attributes.any? do |item_attributes|
          item = existing_items[item_attributes["id"].to_s]
          item_review_reason_resolved?(reason, item: item, submitted_attributes: item_attributes)
        end
      end
    end

    private

    def item_review_reason_resolved?(reason, item:, submitted_attributes:)
      fields = ITEM_REVIEW_FIELD_RULES[reason]
      return false if fields.blank?

      attributes = submitted_attributes.to_h.stringify_keys
      fields.any? { |field| item_review_field_changed?(item, attributes, field) }
    end

    def item_review_field_changed?(item, attributes, field)
      return false unless attributes.key?(field)
      return attributes[field].present? if item.nil?

      normalize_item_review_value(item.public_send(field), field) !=
        normalize_item_review_value(attributes[field], field)
    end

    def normalize_item_review_value(value, field)
      return nil if value.blank?
      return BigDecimal(value.to_s) if ITEM_DECIMAL_FIELDS.include?(field)

      value.to_s
    rescue ArgumentError
      nil
    end

    def submitted_item_attributes(permitted)
      value = permitted["receipt_items_attributes"] || permitted[:receipt_items_attributes]
      return [] if value.blank?

      collection = value.respond_to?(:values) ? value.values : Array(value)
      collection.filter_map do |attributes|
        next unless attributes.respond_to?(:to_h)
        next if ActiveModel::Type::Boolean.new.cast(attributes.to_h["_destroy"] || attributes.to_h[:_destroy])

        attributes.to_h.stringify_keys
      end
    end
  end

  def initialize(receipt:, permitted:, amount_result:, consistency_review_reasons:, child_review_remaining:, nested_amount_inputs_submitted:, item_inputs_submitted:)
    @receipt = receipt
    @permitted = permitted
    @amount_result = amount_result
    @consistency_review_reasons = Array(consistency_review_reasons)
    @child_review_remaining = child_review_remaining
    @nested_amount_inputs_submitted = nested_amount_inputs_submitted
    @item_inputs_submitted = item_inputs_submitted
  end

  def call
    reasons = ReviewReasons.review_reasons_for_user(receipt.review_reasons)
    if nested_amount_inputs_submitted
      reasons -= ReviewReasons::AMOUNT_REASONS
    end
    if item_inputs_submitted
      reasons -= self.class.resolved_item_review_reasons(receipt: receipt, permitted: permitted)
      reasons.delete("items_missing") if effective_item_present?
    end
    reasons |= current_amount_review_reasons
    reasons |= ReviewReasons.review_reasons_for_user(consistency_review_reasons)
    reasons = synchronize_core_field_reasons(reasons)

    Result.new(
      review_reasons: reasons,
      status: review_needed?(reasons) ? "review_needed" : "completed"
    )
  end

  private

  attr_reader :receipt,
              :permitted,
              :amount_result,
              :consistency_review_reasons,
              :child_review_remaining,
              :nested_amount_inputs_submitted,
              :item_inputs_submitted

  def current_amount_review_reasons
    reasons =
      if amount_result.respond_to?(:key?) && amount_result.key?(:review_reasons)
        amount_result[:review_reasons]
      elsif amount_result.respond_to?(:key?) && amount_result.key?(:blocking_inconsistencies)
        amount_result[:blocking_inconsistencies]
      else
        amount_result[:inconsistencies]
      end

    ReviewReasons.review_reasons_for_user(reasons)
  end

  def synchronize_core_field_reasons(reasons)
    FIELD_REVIEW_RULES.each_with_object(reasons.dup) do |(field, rule), result|
      value = effective_value(field)
      if value.blank?
        result << rule.fetch(:missing)
      elsif permitted.key?(field.to_s) || result.include?(rule.fetch(:missing))
        result.delete_if { |reason| rule.fetch(:resolved).include?(reason) }
      end
    end.uniq
  end

  def effective_value(field)
    return permitted[field.to_s] if permitted.key?(field.to_s)

    receipt.public_send(field)
  end

  def effective_item_present?
    submitted = permitted["receipt_items_attributes"]
    return receipt.receipt_items.present? if submitted.blank?

    attributes = submitted.respond_to?(:values) ? submitted.values : Array(submitted)
    destroyed_ids = attributes.filter_map do |item_attributes|
      item_attributes = item_attributes.to_h.stringify_keys
      item_attributes["id"].to_s.presence if ActiveModel::Type::Boolean.new.cast(item_attributes["_destroy"])
    end
    submitted_item_present = attributes.any? do |item_attributes|
      !ActiveModel::Type::Boolean.new.cast(item_attributes.to_h.stringify_keys["_destroy"])
    end

    submitted_item_present || receipt.receipt_items.any? { |item| !destroyed_ids.include?(item.id.to_s) }
  end

  def review_needed?(reasons)
    reasons.present? || child_review_remaining || unexplained_existing_review?
  end

  def unexplained_existing_review?
    receipt.review_needed? &&
      ReviewReasons.review_reasons_for_user(receipt.review_reasons).empty? &&
      !item_inputs_submitted
  end
end
