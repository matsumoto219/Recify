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
  ADJUSTMENT_REVIEW_REASON = "adjustment_uncertain"

  FIELD_REVIEW_RULES = {
    store_name: {
      missing: "store_name_missing",
      resolved_on_change: %w[store_name_uncertain]
    },
    store_address: {
      missing: "store_address_missing",
      resolved_on_change: %w[store_address_uncertain]
    },
    store_phone_number: {
      missing: "store_phone_number_missing",
      resolved_on_change: %w[store_phone_number_uncertain]
    },
    purchased_at: {
      missing: "purchased_at_missing",
      resolved_on_change: %w[purchased_at_uncertain purchased_at_conflicted]
    },
    payment_method: {
      missing: "payment_method_missing",
      resolved_on_change: %w[payment_method_uncertain]
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

    def item_review_state(item:, submitted_attributes:, inherited_review_reasons: [])
      stored_reasons = item_review_reasons(item)
      inherited_reasons = inherited_item_review_reasons(item, inherited_review_reasons)
      evaluation_reasons = stored_reasons | inherited_reasons
      resolved_reasons = evaluation_reasons.select do |reason|
        item_review_reason_resolved?(reason, item: item, submitted_attributes: submitted_attributes)
      end
      remaining_evaluation_reasons = evaluation_reasons - resolved_reasons
      remaining_stored_reasons = stored_reasons - resolved_reasons
      blocking_reason_remaining = ReviewReasons.blocking_reasons_for_user(remaining_evaluation_reasons).present?
      blocking_reason_resolved = ReviewReasons.blocking_reasons_for_user(resolved_reasons).present?
      existing_review_remaining = item.needs_review? &&
        (remaining_evaluation_reasons.present? || resolved_reasons.empty?) &&
        !(blocking_reason_resolved && !blocking_reason_remaining)
      needs_review = blocking_reason_remaining || existing_review_remaining
      materialized_warnings = if blocking_reason_resolved && !blocking_reason_remaining
        ReviewReasons.warning_reasons_for_user(inherited_reasons - resolved_reasons)
      else
        []
      end

      ItemResult.new(
        review_reasons: remaining_stored_reasons | materialized_warnings,
        needs_review: needs_review
      )
    end

    def resolved_item_review_reasons(receipt:, permitted:)
      attributes = submitted_item_attributes(permitted)
      attributes_by_id = attributes.index_by { |item_attributes| item_attributes["id"].to_s }
      existing_items = receipt.receipt_items.index_by { |item| item.id.to_s }

      ITEM_REVIEW_FIELD_RULES.keys.select do |reason|
        reviewed_items = item_review_candidates(receipt, reason)
        if reviewed_items.empty?
          next attributes.any? do |submitted_attributes|
            item = existing_items[submitted_attributes["id"].to_s]
            !destroyed_attributes?(submitted_attributes) &&
              item_review_reason_resolved?(
                reason,
                item: item,
                submitted_attributes: submitted_attributes
              )
          end
        end

        reviewed_items.none? do |item|
          item_review_reason_remaining?(
            reason,
            item: item,
            submitted_attributes: attributes_by_id[item.id.to_s]
          )
        end
      end
    end

    private

    def item_review_candidates(receipt, reason)
      receipt.receipt_items.select do |item|
        item.needs_review? || item_review_reasons(item).include?(reason)
      end
    end

    def inherited_item_review_reasons(item, reasons)
      return [] unless item.needs_review?

      ReviewReasons.review_reasons_for_user(reasons).select do |reason|
        ITEM_REVIEW_FIELD_RULES.key?(reason)
      end
    end

    def item_review_reasons(item)
      Array(item.review_reasons).map(&:to_s).reject(&:blank?)
    end

    def item_review_reason_resolved?(reason, item:, submitted_attributes:)
      fields = ITEM_REVIEW_FIELD_RULES[reason]
      return false if fields.blank?

      attributes = submitted_attributes.to_h.stringify_keys
      return false unless fields.any? { |field| item_review_field_changed?(item, attributes, field) }

      item_review_fields_valid?(item, attributes, fields)
    end

    def item_review_reason_remaining?(reason, item:, submitted_attributes:)
      return true if submitted_attributes.blank?
      return false if destroyed_attributes?(submitted_attributes)

      !item_review_reason_resolved?(reason, item: item, submitted_attributes: submitted_attributes)
    end

    def item_review_fields_valid?(item, attributes, fields)
      candidate = item ? item.dup : ReceiptItem.new
      candidate.assign_attributes(attributes.slice(*fields))
      candidate.valid?(:update)

      fields.all? do |field|
        candidate.public_send(field).present? && candidate.errors[field].empty?
      end
    rescue ActiveModel::UnknownAttributeError, ArgumentError, TypeError
      false
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

        attributes.to_h.stringify_keys
      end
    end

    def destroyed_attributes?(attributes)
      ActiveModel::Type::Boolean.new.cast(attributes["_destroy"])
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
      reasons -= ReviewReasons::AMOUNT_REASONS - [ ADJUSTMENT_REVIEW_REASON ]
    end
    reasons.delete(ADJUSTMENT_REVIEW_REASON) if adjustment_review_reason_resolved?
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

  def adjustment_review_reason_resolved?
    attributes = submitted_adjustment_attributes
    return false if attributes.empty?

    attributes_by_id = attributes.index_by { |item| item["id"].to_s }
    reviewed_adjustments = adjustment_review_candidates

    if reviewed_adjustments.present?
      return reviewed_adjustments.none? do |adjustment|
        adjustment_review_reason_remaining?(
          adjustment,
          submitted_attributes: attributes_by_id[adjustment.id.to_s]
        )
      end
    end

    legacy_adjustment_review_resolved?(attributes, attributes_by_id)
  end

  def adjustment_review_candidates
    receipt.receipt_adjustments.select do |adjustment|
      reasons = adjustment_review_reasons(adjustment)
      reasons.include?(ADJUSTMENT_REVIEW_REASON) || (adjustment.needs_review? && reasons.empty?)
    end
  end

  def adjustment_review_reason_remaining?(adjustment, submitted_attributes:)
    return true if submitted_attributes.blank?
    return false if destroyed_adjustment_attributes?(submitted_attributes)

    !adjustment_review_confirmed_by_server?(submitted_attributes)
  end

  def legacy_adjustment_review_resolved?(submitted_attributes, attributes_by_id)
    existing_adjustment_resolved = receipt.receipt_adjustments.any? do |adjustment|
      item_attributes = attributes_by_id[adjustment.id.to_s]
      item_attributes.present? &&
        (destroyed_adjustment_attributes?(item_attributes) || adjustment_review_confirmed_by_server?(item_attributes))
    end
    existing_adjustment_resolved || new_adjustment_confirmed_by_server?(submitted_attributes)
  end

  def adjustment_review_confirmed_by_server?(attributes)
    attributes["source"] == "manual" &&
      attributes.key?("needs_review") &&
      ActiveModel::Type::Boolean.new.cast(attributes["needs_review"]) == false &&
      attributes.key?("review_reasons") &&
      Array(attributes["review_reasons"]).reject(&:blank?).empty?
  end

  def new_adjustment_confirmed_by_server?(attributes)
    attributes.any? do |attributes|
      attributes["id"].blank? &&
        !destroyed_adjustment_attributes?(attributes) &&
        adjustment_review_confirmed_by_server?(attributes)
    end
  end

  def adjustment_review_reasons(adjustment)
    Array(adjustment.review_reasons).map(&:to_s).reject(&:blank?)
  end

  def submitted_adjustment_attributes
    value = permitted["receipt_adjustments_attributes"] || permitted[:receipt_adjustments_attributes]
    return [] if value.blank?

    collection = value.respond_to?(:values) ? value.values : Array(value)
    collection.filter_map do |attributes|
      attributes.to_h.stringify_keys if attributes.respond_to?(:to_h)
    end
  end

  def destroyed_adjustment_attributes?(attributes)
    ActiveModel::Type::Boolean.new.cast(attributes["_destroy"])
  end

  def synchronize_core_field_reasons(reasons)
    FIELD_REVIEW_RULES.each_with_object(reasons.dup) do |(field, rule), result|
      value = effective_value(field)
      result.delete(rule.fetch(:missing)) if value.present?
      next unless field_changed?(field)

      result.delete_if { |reason| rule.fetch(:resolved_on_change).include?(reason) }
    end.uniq
  end

  def effective_value(field)
    return permitted[field.to_s] if permitted.key?(field.to_s)

    receipt.public_send(field)
  end

  def field_changed?(field)
    return false unless permitted.key?(field.to_s)

    normalized_field_value(field, permitted[field.to_s]) !=
      normalized_field_value(field, receipt.public_send(field))
  end

  def normalized_field_value(field, value)
    return normalized_store_phone_number(value) if field == :store_phone_number

    receipt.class.type_for_attribute(field.to_s).cast(value).presence
  end

  def normalized_store_phone_number(value)
    comparable_receipt = receipt.dup
    comparable_receipt.store_phone_number = value
    comparable_receipt.display_store_phone_number.presence
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
    ReviewReasons.blocking_reasons_for_user(reasons).present? ||
      amount_review_required? ||
      child_review_remaining ||
      unexplained_existing_review?
  end

  def amount_review_required?
    amount_result.respond_to?(:key?) &&
      amount_result.key?(:needs_review) &&
      amount_result[:needs_review] == true
  end

  def unexplained_existing_review?
    receipt.review_needed? &&
      ReviewReasons.review_reasons_for_user(receipt.review_reasons).empty? &&
      !item_inputs_submitted
  end
end
