# frozen_string_literal: true

class Receipts::Editing::ConsistencyGuard
  Result = Data.define(:fatal_errors, :review_reasons) do
    def consistent?
      fatal_errors.empty?
    end
  end

  def self.call(receipt_items:, receipt_adjustments:, receipt_payments:, amount_result:)
    new(
      receipt_items: receipt_items,
      receipt_adjustments: receipt_adjustments,
      receipt_payments: receipt_payments,
      amount_result: amount_result
    ).call
  end

  def initialize(receipt_items:, receipt_adjustments:, receipt_payments:, amount_result:)
    @receipt_items = Array(receipt_items)
    @receipt_adjustments = Array(receipt_adjustments)
    @receipt_payments = Array(receipt_payments)
    @amount_result = amount_result
  end

  def call
    Result.new(
      fatal_errors: fatal_errors,
      review_reasons: review_reasons
    )
  end

  private

  def fatal_errors
    errors = []
    errors << :resolved_purchase_total_mismatch if resolved_purchase_total_mismatch?
    errors << :child_purchase_total_mismatch if child_purchase_total_mismatch?
    errors << :final_payment_total_mismatch if final_payment_total_mismatch?
    errors << :payment_sum_snapshot_mismatch if payment_sum_snapshot_mismatch?
    errors
  end

  def review_reasons
    reasons = ReviewReasons.review_reasons_for_user(fetch_value(@amount_result, :review_reasons))
    reasons << "payment_amount_mismatch" if payment_mismatch?

    if unsafe_candidate? && reasons.empty?
      reasons << "calculation_profile_uncertain"
    end

    reasons.uniq
  end

  def resolved_purchase_total_mismatch?
    computed_purchase_total = amount_result_value(:computed, :purchase_total)
    resolved_total = amount_result_value(:resolved, :total)
    return false if computed_purchase_total.nil? || resolved_total.nil?

    computed_purchase_total != resolved_total
  end

  def child_purchase_total_mismatch?
    return false if @receipt_items.empty?
    return false if receipt_input_without_item_amounts?

    computed_adjusted_item_total = amount_result_value(:computed, :adjusted_item_total)
    resolved_total = amount_result_value(:resolved, :total)
    return false if computed_adjusted_item_total.nil? || resolved_total.nil?

    return true if item_total + purchase_adjustment_total != computed_adjusted_item_total

    expected_purchase_total =
      if fetch_value(fetch_value(@amount_result, :computed), :receipt_tax_basis).to_s == "tax_added_to_subtotal"
        computed_adjusted_item_total + amount_result_value(:computed, :tax).to_i
      else
        computed_adjusted_item_total
      end

    expected_purchase_total != resolved_total
  end

  def receipt_input_without_item_amounts?
    computed = fetch_value(@amount_result, :computed)
    return false unless fetch_value(computed, :amount_engine_basis).to_s == "receipt_input_preserved"

    @receipt_items.none? { |item| item_amount_source_present?(item) }
  end

  def item_amount_source_present?(item)
    value_present?(fetch_value(item, :price)) ||
      value_present?(fetch_value(item, :line_total)) ||
      positive_amount?(fetch_value(item, :original_line_total)) ||
      positive_amount?(fetch_value(item, :discount_amount))
  end

  def value_present?(value)
    !value.nil? && value.to_s.strip != ""
  end

  def positive_amount?(value)
    ReceiptAmountService.parse_amount(value).positive?
  end

  def final_payment_total_mismatch?
    final_payment_total = amount_result_value(:computed, :final_payment_total)
    purchase_total = amount_result_value(:computed, :purchase_total)
    payment_adjustment_total = amount_result_value(:computed, :payment_adjustment_total)
    return false if final_payment_total.nil? || purchase_total.nil? || payment_adjustment_total.nil?

    purchase_total + payment_adjustment_total != final_payment_total
  end

  def payment_sum_snapshot_mismatch?
    payment_amount_sum = amount_result_value(:computed, :payment_amount_sum)
    return false if payment_amount_sum.nil?

    payment_total != payment_amount_sum
  end

  def payment_mismatch?
    return false if @receipt_payments.empty?

    final_payment_total = amount_result_value(:computed, :final_payment_total)
    return false if final_payment_total.nil?

    payment_total != final_payment_total
  end

  def unsafe_candidate?
    fetch_value(@amount_result, :safe_to_auto_complete) == false ||
      fetch_value(@amount_result, :selected_candidate_status).to_s == "rejected"
  end

  def item_total
    @receipt_items.sum { |item| amount_value(item, :line_total) }
  end

  def purchase_adjustment_total
    @receipt_adjustments.sum do |adjustment|
      classification = ReceiptAmountService.adjustment_classification(adjustment)
      classification[:effect] == :payment_adjustment ? 0 : classification[:signed_amount].to_i
    end
  end

  def payment_total
    @receipt_payments.sum { |payment| amount_value(payment, :amount) }
  end

  def amount_result_value(section, key)
    amount = fetch_value(fetch_value(@amount_result, section), key)
    return nil if amount.nil?

    ReceiptAmountService.parse_amount(amount)
  end

  def amount_value(value, key)
    ReceiptAmountService.parse_amount(fetch_value(value, key))
  end

  def fetch_value(value, key)
    return nil if value.nil?

    if value.respond_to?(:key?)
      return value[key] if value.key?(key)
      return value[key.to_s] if value.key?(key.to_s)
    end

    value.public_send(key) if value.respond_to?(key)
  end
end
