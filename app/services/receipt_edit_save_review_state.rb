# frozen_string_literal: true

class ReceiptEditSaveReviewState
  Result = Data.define(:review_reasons, :status)
  ITEM_CONFIRMABLE_REASONS = (
    ReviewReasons::OCR_REASONS +
    ReviewReasons::AI_REASONS.select { |reason| reason.start_with?("item_") || reason == "items_missing" }
  ).freeze

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

  def self.call(receipt:, permitted:, amount_result:, consistency_review_reasons:, child_review_remaining:, nested_amount_inputs_submitted:, item_inputs_submitted:)
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
      reasons -= ITEM_CONFIRMABLE_REASONS
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

  def review_needed?(reasons)
    reasons.present? || child_review_remaining || unexplained_existing_review?
  end

  def unexplained_existing_review?
    receipt.review_needed? &&
      ReviewReasons.review_reasons_for_user(receipt.review_reasons).empty? &&
      !item_inputs_submitted
  end
end
