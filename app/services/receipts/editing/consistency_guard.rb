# frozen_string_literal: true

class Receipts::Editing::ConsistencyGuard
  Result = Data.define(:fatal_errors, :review_reasons) do
    def consistent?
      fatal_errors.empty?
    end
  end

  ITEM_SOURCE_FIELDS = %i[
    pricing_source_kind
    price
    quantity
    quantity_unit_code
    quantity_unit_raw
    input_tax_inclusion
    reference_price_amount
    reference_quantity
    reference_quantity_unit_code
    reference_quantity_unit_raw
    reference_price_tax_inclusion
    tax_rate
    discount_rate
    discount_amount
    original_line_total
    line_total
  ].freeze
  ITEM_NUMERIC_SOURCE_FIELDS = %i[
    price
    quantity
    reference_price_amount
    reference_quantity
    tax_rate
    discount_rate
    discount_amount
    original_line_total
    line_total
  ].freeze

  def self.call(receipt_items:, receipt_adjustments:, receipt_payments:, amount_result:, calculation_settings: nil)
    new(
      receipt_items: receipt_items,
      receipt_adjustments: receipt_adjustments,
      receipt_payments: receipt_payments,
      amount_result: amount_result,
      calculation_settings: calculation_settings
    ).call
  end

  def initialize(receipt_items:, receipt_adjustments:, receipt_payments:, amount_result:, calculation_settings: nil)
    @receipt_items = Array(receipt_items)
    @receipt_adjustments = Array(receipt_adjustments)
    @receipt_payments = Array(receipt_payments)
    @amount_result = amount_result
    @calculation_settings = calculation_settings
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
    if !@calculation_settings.nil? && !legacy_receipt_input?
      return managed_child_purchase_total_mismatch?
    end

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

  def legacy_receipt_input?
    computed = fetch_value(@amount_result, :computed)
    return false unless fetch_value(computed, :amount_engine_basis).to_s == "receipt_input_preserved"

    @receipt_items.none? do |item|
      fetch_value(item, :pricing_source_kind).present? || fetch_value(item, :input_tax_inclusion).present?
    end
  end

  def managed_child_purchase_total_mismatch?
    return true unless ReceiptCalculationSettings.parse(@calculation_settings)
    status = fetch_value(@amount_result, :selected_candidate_status)
    return true unless %w[accepted rejected].include?(status) &&
      fetch_value(fetch_value(@amount_result, :amount_engine), :selected_candidate_status) == status

    computed = fetch_value(@amount_result, :computed)
    basis = fetch_value(computed, :amount_engine_basis).to_s
    return true unless %w[items_as_tax_included items_as_tax_excluded].include?(basis)

    sources = fetch_value(computed, :source_items)
    projections = fetch_value(computed, :items)
    triplets = managed_item_triplets(sources, projections)
    return true unless triplets
    return true if triplets.any? { |item, source, projection| managed_item_mismatch?(item, source, projection) }
    return true if purchase_adjustment_total != amount_result_value(:computed, :purchase_adjustment_total)

    managed_tax_groups_mismatch?(fetch_value(computed, :tax_rate_groups))
  end

  def managed_item_triplets(sources, projections)
    return unless sources.is_a?(Array) && projections.is_a?(Array)
    return unless sources.size == @receipt_items.size && projections.size == sources.size

    saved_ids = @receipt_items.filter_map { |item| fetch_value(item, :id).to_s.presence }
    source_ids = sources.filter_map { |item| fetch_value(item, :id).to_s.presence }
    return unless saved_ids.uniq.size == saved_ids.size && source_ids.uniq.size == source_ids.size
    return unless saved_ids.to_set == source_ids.to_set

    sources_by_id = {}
    new_sources = []
    sources.each_with_index do |source, index|
      projection = projections[index]
      id = fetch_value(source, :id).to_s.presence
      return unless id == fetch_value(projection, :id).to_s.presence

      pair = [ source, projection ]
      if id
        sources_by_id[id] = pair
      else
        new_sources << pair
      end
    end
    @receipt_items.map do |item|
      id = fetch_value(item, :id).to_s.presence
      source, projection = id ? sources_by_id[id] : new_sources.shift
      [ item, source, projection ]
    end
  end

  def managed_item_mismatch?(item, source, projection)
    source_mismatch = ITEM_SOURCE_FIELDS.any? do |field|
      next false if field == :price && fetch_value(source, :pricing_source_kind) == "reference_quantity_price"

      actual = fetch_value(item, field)
      expected = fetch_value(source, field)
      if ITEM_NUMERIC_SOURCE_FIELDS.include?(field)
        !exact_numeric_match?(actual, expected)
      else
        actual != expected
      end
    end
    gross = fetch_value(item, :gross_line_total)
    projected_gross = fetch_value(projection, :line_total)
    source_mismatch || gross.nil? || projected_gross.nil? || !exact_numeric_match?(gross, projected_gross)
  end

  def managed_tax_groups_mismatch?(groups)
    return true unless groups.is_a?(Array) && groups.present?

    totals = { gross: 0, net: 0, tax: 0 }
    rates = Set.new
    groups.each do |group|
      rate = exact_decimal(fetch_value(group, :rate))
      return true unless rate && rate.between?(0, 1) && !rates.include?(rate)

      rates.add(rate)
      amounts = totals.keys.to_h { |key| [ key, exact_decimal(fetch_value(group, key)) ] }
      return true unless amounts.values.all? { |value| value && value >= 0 && value.frac.zero? }
      return true unless amounts[:net] + amounts[:tax] == amounts[:gross]

      totals.each_key { |key| totals[key] += amounts[key] }
    end

    { gross: :total, net: :subtotal, tax: :tax }.any? do |key, resolved_key|
      !exact_numeric_match?(totals[key], fetch_value(fetch_value(@amount_result, :resolved), resolved_key))
    end
  end

  def exact_numeric_match?(actual, expected)
    return actual.nil? if expected.nil?

    actual_number = exact_decimal(actual)
    expected_number = exact_decimal(expected)
    actual_number && expected_number && actual_number == expected_number
  end

  def exact_decimal(value)
    return unless value.is_a?(Numeric) || value.is_a?(String)

    text = value.to_s
    return unless text.bytesize <= 128 && text.valid_encoding? &&
      text.match?(/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/)

    decimal = BigDecimal(text, exception: false)
    decimal if decimal&.finite? && decimal.exponent.abs <= 128
  end

  def receipt_input_without_item_amounts?
    computed = fetch_value(@amount_result, :computed)
    return false unless fetch_value(computed, :amount_engine_basis).to_s == "receipt_input_preserved"

    @receipt_items.none? { |item| item_amount_source_present?(item) }
  end

  def item_amount_source_present?(item)
    value_present?(fetch_value(item, :pricing_source_kind)) ||
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
    if @amount_result.respond_to?(:key?) &&
        (@amount_result.key?(:payment_reconciliation) || @amount_result.key?("payment_reconciliation"))
      reconciliation = fetch_value(@amount_result, :payment_reconciliation)
      return true unless reconciliation.respond_to?(:key?) &&
        (reconciliation.key?(:payment_amount_sum) || reconciliation.key?("payment_amount_sum")) &&
        (reconciliation.key?(:final_payment_total) || reconciliation.key?("final_payment_total"))

      actual_payment_total = @receipt_payments.empty? ? nil : payment_total
      return actual_payment_total != amount_result_value(:payment_reconciliation, :payment_amount_sum)
    end

    payment_amount_sum = amount_result_value(:computed, :payment_amount_sum)
    return false if payment_amount_sum.nil?

    payment_total != payment_amount_sum
  end

  def payment_mismatch?
    return false if @receipt_payments.empty?

    section = if @amount_result.respond_to?(:key?) &&
        (@amount_result.key?(:payment_reconciliation) || @amount_result.key?("payment_reconciliation"))
      :payment_reconciliation
    else
      :computed
    end
    final_payment_total = amount_result_value(section, :final_payment_total)
    return false if final_payment_total.nil?
    return false if payment_total.nil?

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
    amounts = @receipt_payments.map { |payment| fetch_value(payment, :amount) }
    return nil if amounts.any?(&:nil?)

    amounts.sum { |amount| ReceiptAmountService.parse_amount(amount) }
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
