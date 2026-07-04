# frozen_string_literal: true

# Entry point for amount calculation / resolution / consistency checks.
# This service is intentionally DB-agnostic and works with Hash inputs
# (e.g., params[:receipt_items_attributes]) to keep it pure and testable.
#
# Expected input shapes:
# - receipt: ActiveRecord object or Hash-like with:
#     :total_amount, :subtotal_amount, :tax_amount
# - receipt_items: Array<Hash> with:
#     :price, :quantity, :line_total (optional), :tax_rate (optional)
# - receipt_tax_details: Array<Hash> with:
#     :amount, :rate, :net_amount (optional)
# - receipt_adjustments: Array<Hash> with:
#     :amount, :sign, :kind, :needs_review, :review_reasons
# - receipt_payments: Array<Hash> with:
#     :method, :amount
#
# Output:
# {
#   computed: { subtotal:, tax:, total:, tax_rate: },
#   resolved: { subtotal:, tax:, total:, tax_rate: },
#   tax_details: Array<Hash>,
#   inconsistencies: Array<Symbol>,
#   mismatch_codes: Array<String>,
#   mismatch_messages: Array<String>,
#   calculation_profile: Hash?,
#   calculation_profile_score: Integer?,
#   calculation_profile_candidates: Array<Hash>,
#   amount_engine: {
#     selected_candidate_status: "accepted" | "rejected",
#     no_safe_candidate: Boolean
#   },
#   selected_candidate_status: "accepted" | "rejected",
#   safe_to_auto_complete: Boolean,
#   context: Symbol,
#   rounding_mode: { tax:, discount: },
#   needs_review: Boolean
# }
#
class ReceiptAmountService
  TAX_EXCLUDED_PRICE_CONVERSION_SETTING_KEY = "amount_engine.tax_excluded_price_conversion_enabled"

  def self.call(receipt:, receipt_items:, receipt_tax_details:, receipt_adjustments: [], receipt_payments: [], context:, rounding_mode: nil, tax_rounding_mode: nil, discount_rounding_mode: nil)
    new(
      receipt: receipt,
      receipt_items: receipt_items,
      receipt_tax_details: receipt_tax_details,
      receipt_adjustments: receipt_adjustments,
      receipt_payments: receipt_payments,
      context: context,
      rounding_mode: rounding_mode,
      tax_rounding_mode: tax_rounding_mode,
      discount_rounding_mode: discount_rounding_mode
    ).call
  end

  def self.calculation_profile_snapshot(result, context: nil, rounding_mode: nil)
    Amounts::CalculationProfileSnapshot.call(
      result,
      context: context,
      rounding_mode: rounding_mode
    )
  end

  def self.parse_amount_or_nil(value)
    Amounts::NumberParser.parse_amount_or_nil(value)
  end

  def self.parse_amount(value, default: 0)
    Amounts::NumberParser.parse_amount(value, default: default)
  end

  def self.parse_quantity(value, default: BigDecimal("1"))
    Amounts::NumberParser.parse_quantity(value, default: default)
  end

  def self.adjustment_classification(adjustment)
    Amounts::AdjustmentClassifier.call(adjustment)
  end

  def self.adjustment_effect(adjustment)
    adjustment_classification(adjustment)[:effect].to_s
  end

  def self.payment_adjustment_kinds
    Amounts::AdjustmentClassifier::PAYMENT_ADJUSTMENT_KINDS
  end

  def self.payment_adjustment_summary(receipt:, receipt_adjustments: nil)
    Amounts::PaymentAdjustmentSummary.call(
      receipt: receipt,
      receipt_adjustments: receipt_adjustments
    )
  end

  def self.warning_mismatch_codes
    Amounts::MismatchSeverity::WARNING
  end

  def initialize(receipt:, receipt_items:, receipt_tax_details:, receipt_adjustments: [], receipt_payments: [], context:, rounding_mode: nil, tax_rounding_mode: nil, discount_rounding_mode: nil)
    @receipt = normalize_receipt(receipt)
    @items = Array(receipt_items).map { |i| normalize_item(i) }
    @tax_details = Array(receipt_tax_details).map { |t| normalize_tax_detail(t) }
    @adjustments = Array(receipt_adjustments).map { |adjustment| normalize_adjustment(adjustment) }
    @payments = Array(receipt_payments).map { |payment| normalize_payment(payment) }
    @adjustments = canonical_adjustments(@adjustments, @payments)
    @payments = canonical_payments(@payments, @adjustments)
    @context = normalize_context(context)
    @tax_rounding_mode_explicit = !rounding_mode.nil? || !tax_rounding_mode.nil?
    @discount_rounding_mode_explicit = !discount_rounding_mode.nil?
    @tax_rounding_mode = Amounts::Rounding.normalize_rounding_mode(
      tax_rounding_mode || rounding_mode || Amounts::Rounding::TAX_DEFAULT_MODE
    )
    @discount_rounding_mode = Amounts::Rounding.normalize_rounding_mode(
      discount_rounding_mode || Amounts::Rounding::DISCOUNT_DEFAULT_MODE
    )
  end

  def call
    tax_excluded_price_conversion_enabled = tax_excluded_price_conversion_enabled?
    profile_estimation = applicable_calculation_profile(estimate_calculation_profile)
    active_profile = profile_estimation.applied_profile || {}
    active_tax_rounding_mode = active_profile[:tax_rounding_mode] || @tax_rounding_mode
    active_discount_rounding_mode = active_profile[:discount_rounding_mode] || @discount_rounding_mode
    active_receipt_tax_basis = active_profile[:receipt_tax_basis] || :total_includes_tax
    base_result = engine_base_result(
      tax_rounding_mode: active_tax_rounding_mode,
      discount_rounding_mode: active_discount_rounding_mode,
      receipt_tax_basis: active_receipt_tax_basis
    )

    Amounts::Engine.new(
      receipt: @receipt,
      items: @items,
      tax_details: @tax_details,
      adjustments: @adjustments,
      payments: @payments,
      context: @context,
      tax_rounding_modes: candidate_tax_rounding_modes,
      discount_rounding_mode: active_discount_rounding_mode,
      discount_rounding_modes: engine_discount_rounding_modes(active_discount_rounding_mode),
      tax_excluded_price_conversion_enabled: tax_excluded_price_conversion_enabled,
      base_result: base_result,
      calculation_profile_result: profile_estimation
    ).call
  end

  private

  def engine_base_result(tax_rounding_mode:, discount_rounding_mode:, receipt_tax_basis:)
    items = Amounts::ItemTotalAggregator.new(
      items: @items,
      context: @context,
      discount_rounding_mode: discount_rounding_mode
    ).call[:items]
    adjustment_summary = adjustment_totals_for(receipt_tax_basis, rounding_mode: tax_rounding_mode)
    item_total = items.sum { |item| to_i(item[:line_total]) }

    {
      context: @context,
      rounding_mode: {
        tax: tax_rounding_mode,
        discount: discount_rounding_mode
      },
      computed: {
        adjustment_discount_total: adjustment_summary[:discount_total],
        adjustment_surcharge_total: adjustment_summary[:surcharge_total],
        payment_adjustment_total: adjustment_summary[:payment_adjustment_total],
        adjustment_tax_rate_missing_total: adjustment_summary[:tax_rate_missing_adjustment_total],
        adjusted_item_total: [ item_total + adjustment_summary[:receipt_total_delta].to_i, 0 ].max,
        items: items
      },
      resolved: {},
      tax_details: [],
      inconsistencies: [],
      mismatch_codes: [],
      mismatch_messages: []
    }
  end

  def applicable_calculation_profile(profile_estimation)
    profile_estimation = Amounts::CalculationProfileResult.wrap(profile_estimation)
    profile = profile_estimation.profile

    profile_estimation.with_applied_profile(applicable_profile?(profile_estimation) ? profile : nil)
  end

  def applicable_profile?(profile_estimation)
    profile = profile_estimation.profile
    return false unless profile_estimation.score.to_i.zero?
    return false unless profile

    case profile[:item_amount_basis]
    when :line_total_as_recorded
      true
    when :line_total_as_net
      tax_excluded_profile_applicable?(profile_estimation)
    when :mixed_by_tax_rate_group
      mixed_profile_applicable?(profile_estimation)
    else
      false
    end
  end

  def tax_excluded_profile_applicable?(profile_estimation)
    profile = profile_estimation.profile

    return false unless @context == :analysis
    return false unless profile[:receipt_tax_basis] == :tax_added_to_subtotal
    return false if profile_estimation.warnings.include?(:calculation_profile_uncertain)
    return false if same_score_conflicting_basis?(profile_estimation, item_amount_basis: :line_total_as_net, receipt_tax_basis: :tax_added_to_subtotal)
    return false unless receipt_amounts_complete_and_consistent?
    return false unless item_line_totals_complete?
    return false unless complete_tax_details_available?
    return false if tax_detail_incomplete?
    return false if mixed_item_amount_basis_suspected?
    return false unless item_line_total_sum == tax_detail_net_amount
    return false unless @receipt[:total_amount] == tax_detail_net_amount + tax_detail_tax_amount
    return false unless external_tax_evidence?
    return false unless safe_tax_rate_coverage?

    true
  end

  def mixed_profile_applicable?(profile_estimation)
    profile = profile_estimation.profile
    assignments = Array(profile[:item_amount_basis_assignments])

    return false unless @context == :analysis
    return false if assignments.blank?
    return false if profile_estimation.warnings.include?(:calculation_profile_uncertain)
    return false if same_score_conflicting_basis?(profile_estimation, item_amount_basis: :mixed_by_tax_rate_group, receipt_tax_basis: profile[:receipt_tax_basis])
    return false unless receipt_amounts_complete_and_consistent?
    return false unless item_line_totals_complete?
    return false unless complete_tax_details_available?
    return false if tax_detail_incomplete?
    return false if discount_data_incomplete?
    return false unless positive_tax_rates_correspond?
    return false unless assignment_tax_details_match?(assignments)
    return false unless assignment_amounts_match_receipt?(assignments)

    true
  end

  def same_score_conflicting_basis?(profile_estimation, item_amount_basis:, receipt_tax_basis:)
    score = profile_estimation.score.to_i

    profile_estimation.candidates.any? do |candidate|
      next false unless candidate[:score].to_i == score

      profile = candidate[:profile]
      profile[:item_amount_basis] != item_amount_basis || profile[:receipt_tax_basis] != receipt_tax_basis
    end
  end

  def receipt_amounts_complete_and_consistent?
    subtotal = @receipt[:subtotal_amount]
    tax = @receipt[:tax_amount]
    total = @receipt[:total_amount]

    value_present?(subtotal) &&
      value_present?(tax) &&
      value_present?(total) &&
      subtotal + tax == total
  end

  def item_line_totals_complete?
    @items.present? && @items.all? { |item| item[:amount_line_total_present] == true }
  end

  def complete_tax_details_available?
    complete_tax_details.present?
  end

  def tax_detail_incomplete?
    @tax_details.any? do |tax_detail|
      tax_detail_has_any_value?(tax_detail) && !tax_detail_complete?(tax_detail)
    end
  end

  def tax_detail_has_any_value?(tax_detail)
    value_present?(tax_detail[:rate]) ||
      value_present?(tax_detail[:net_amount]) ||
      value_present?(tax_detail[:amount])
  end

  def tax_detail_complete?(tax_detail)
    normalize_rate(tax_detail[:rate]).positive? &&
      value_present?(tax_detail[:net_amount]) &&
      value_present?(tax_detail[:amount])
  end

  def complete_tax_details
    @complete_tax_details ||= @tax_details.select { |tax_detail| tax_detail_complete?(tax_detail) }
  end

  def item_line_total_sum
    @item_line_total_sum ||= @items.sum { |item| to_i(item[:line_total]) } + adjustment_totals_for(:tax_added_to_subtotal)[:receipt_total_delta]
  end

  def tax_detail_net_amount
    @tax_detail_net_amount ||= complete_tax_details.sum { |tax_detail| to_i(tax_detail[:net_amount]) }
  end

  def tax_detail_tax_amount
    @tax_detail_tax_amount ||= complete_tax_details.sum { |tax_detail| to_i(tax_detail[:amount]) }
  end

  def external_tax_evidence?
    external_tax_description? ||
      (
        item_line_total_sum == tax_detail_net_amount &&
          @receipt[:total_amount] == tax_detail_net_amount + tax_detail_tax_amount
      )
  end

  def external_tax_description?
    @tax_details.any? do |tax_detail|
      tax_detail[:description].to_s.match?(profile.analysis_external_tax_description_pattern)
    end
  end

  def profile
    ReceiptAnalysisProfiles.default
  end

  def safe_tax_rate_coverage?
    item_rates = positive_item_tax_rates
    detail_rates = positive_tax_detail_rates

    return false if detail_rates.blank?
    return true if item_rates.blank? && detail_rates.one?
    return false if item_rates.blank?

    (item_rates - detail_rates).empty?
  end

  def positive_tax_rates_correspond?
    (positive_item_tax_rates | positive_adjustment_tax_rates).map(&:to_s).sort == positive_tax_detail_rates.map(&:to_s).sort
  end

  def assignment_tax_details_match?(assignments)
    assignment_tax_details_by_rate(assignments) == tax_details_by_rate(complete_tax_details)
  end

  def assignment_amounts_match_receipt?(assignments)
    assignment_subtotal = assignments.sum { |assignment| to_i(assignment[:net_amount]) }
    assignment_tax = assignments.sum { |assignment| to_i(assignment[:tax_amount]) }
    assignment_total = assignments.sum { |assignment| to_i(assignment[:gross_amount]) }

    assignment_subtotal == @receipt[:subtotal_amount] &&
      assignment_tax == @receipt[:tax_amount] &&
      assignment_total == @receipt[:total_amount]
  end

  def assignment_tax_details_by_rate(assignments)
    assignments.each_with_object({}) do |assignment, groups|
      rate = normalize_rate(assignment[:tax_rate])
      next if rate <= 0

      groups[rate] ||= { amount: 0, net_amount: 0 }
      groups[rate][:amount] += to_i(assignment[:tax_amount])
      groups[rate][:net_amount] += to_i(assignment[:net_amount])
    end
  end

  def tax_details_by_rate(tax_details)
    tax_details.each_with_object({}) do |tax_detail, groups|
      rate = normalize_rate(tax_detail[:rate])
      next if rate <= 0

      groups[rate] ||= { amount: 0, net_amount: 0 }
      groups[rate][:amount] += to_i(tax_detail[:amount])
      groups[rate][:net_amount] += to_i(tax_detail[:net_amount])
    end
  end

  def discount_data_incomplete?
    @items.any? do |item|
      to_i(item[:discount_amount]).positive? && to_i(item[:original_line_total]) <= 0
    end
  end

  def mixed_item_amount_basis_suspected?
    item_rates = @items.map { |item| normalize_rate(item[:tax_rate]) }.uniq

    item_rates.include?(BigDecimal("0")) && item_rates.any?(&:positive?)
  end

  def positive_item_tax_rates
    @items.filter_map do |item|
      rate = normalize_rate(item[:tax_rate])
      rate.positive? ? rate : nil
    end.uniq
  end

  def positive_adjustment_tax_rates
    @adjustments.filter_map do |adjustment|
      next if Amounts::AdjustmentClassifier.payment_adjustment?(adjustment)

      rate = normalize_rate(adjustment[:tax_rate])
      rate.positive? ? rate : nil
    end.uniq
  end

  def positive_tax_detail_rates
    complete_tax_details.filter_map do |tax_detail|
      rate = normalize_rate(tax_detail[:rate])
      rate.positive? ? rate : nil
    end.uniq
  end

  def estimate_calculation_profile
    return empty_calculation_profile unless @context == :analysis

    scored_candidates = native_profile_candidates
    Amounts::ProfileSummary.call(
      selected_candidate: Amounts::WinnerSelector.new(scored_candidates).call,
      candidates: scored_candidates,
      context: @context,
      receipt: @receipt,
      items: @items,
      tax_details: @tax_details
    )
  end

  def candidate_tax_rounding_modes
    @tax_rounding_mode_explicit ? [ @tax_rounding_mode ] : Amounts::CandidateGenerator::ROUNDING_MODES
  end

  def candidate_discount_rounding_modes
    @discount_rounding_mode_explicit ? [ @discount_rounding_mode ] : Amounts::CandidateGenerator::ROUNDING_MODES
  end

  def engine_discount_rounding_modes(active_discount_rounding_mode)
    return [ active_discount_rounding_mode ] unless @context == :analysis

    candidate_discount_rounding_modes
  end

  def empty_calculation_profile
    Amounts::CalculationProfileResult.new
  end

  def native_profile_candidates
    raw_candidates = Amounts::CandidateGenerator.new(
      receipt: @receipt,
      items: @items,
      tax_details: @tax_details,
      adjustments: @adjustments,
      payments: @payments,
      context: @context,
      tax_rounding_modes: candidate_tax_rounding_modes,
      discount_rounding_modes: candidate_discount_rounding_modes,
      tax_excluded_price_conversion_enabled: tax_excluded_price_conversion_enabled?
    ).call
    normalized_items = Amounts::ItemTotalAggregator.new(
      items: @items,
      context: @context,
      discount_rounding_mode: @discount_rounding_mode
    ).call[:items]
    hard_rejector = Amounts::HardRejector.new(
      receipt: @receipt,
      items: normalized_items,
      tax_details: @tax_details,
      payments: @payments
    )
    reviewer = Amounts::CandidateConsistencyReviewer.new(
      receipt: @receipt,
      items: normalized_items,
      tax_details: @tax_details,
      context: @context
    )
    scorer = Amounts::CandidateScorer.new(
      receipt: @receipt,
      payments: @payments,
      tax_details: @tax_details,
      context: @context
    )

    raw_candidates.map { |candidate| scorer.call(reviewer.call(hard_rejector.call(candidate))) }
  end

  def tax_excluded_price_conversion_enabled?
    return true unless @context == :analysis

    SystemSettings.enabled?(TAX_EXCLUDED_PRICE_CONVERSION_SETTING_KEY)
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError
    false
  end

  def normalize_context(value)
    context = value.to_s.to_sym
    %i[analysis edit_save manual].include?(context) ? context : :analysis
  end

  # -----------------------------
  # Normalizers (accept Hash/AR)
  # -----------------------------
  def normalize_receipt(r)
    {
      total_amount: to_i_or_nil(fetch_value(r, :total_amount)),
      subtotal_amount: to_i_or_nil(fetch_value(r, :subtotal_amount)),
      tax_amount: to_i_or_nil(fetch_value(r, :tax_amount)),
      tax_rate: fetch_value(r, :tax_rate)
    }
  end

  def normalize_item(i)
    price = fetch_value(i, :price)
    quantity = fetch_value(i, :quantity)
    original_line_total = fetch_value(i, :original_line_total)
    line_total = fetch_value(i, :line_total)
    discount_amount = fetch_value(i, :discount_amount)
    quantity_unit_code = ReceiptQuantityUnit.normalize(fetch_value(i, :quantity_unit_code))

    {
      price: to_i_or_nil(price),
      quantity: to_decimal_or_nil(quantity),
      original_line_total: to_i_or_nil(original_line_total),
      line_total: to_i_or_nil(line_total),
      discount_amount: to_i_or_nil(discount_amount),
      discount_rate: fetch_value(i, :discount_rate),
      quantity_unit_code: quantity_unit_code,
      tax_rate: fetch_value(i, :tax_rate),
      amount_price_present: value_present?(price),
      amount_quantity_present: value_present?(quantity),
      amount_line_total_present: value_present?(line_total),
      amount_discount_amount_present: value_present?(discount_amount)
    }
  end

  def normalize_adjustment(adjustment)
    normalized =
      if adjustment.respond_to?(:attributes)
        adjustment.attributes.symbolize_keys
      elsif adjustment.respond_to?(:to_h)
        adjustment.to_h.symbolize_keys
      else
        {}
      end
    kind = ReceiptAdjustment.normalize_kind(normalized[:kind])
    sign = normalized[:sign].to_s
    amount = to_i_or_nil(normalized[:amount])

    {
      kind: ReceiptAdjustment::KINDS.include?(kind) ? kind : "other",
      sign: ReceiptAdjustment::SIGNS.include?(sign) ? sign : default_adjustment_sign(kind),
      amount: amount.nil? ? 0 : amount.abs,
      tax_rate: normalize_rate(normalized[:tax_rate]),
      needs_review: normalized[:needs_review] == true,
      review_reasons: Array(normalized[:review_reasons]).map(&:to_s),
      source: normalized[:source],
      label: normalized[:label],
      source_text: normalized[:source_text],
      source_line_index: normalized[:source_line_index]
    }
  end

  def normalize_payment(payment)
    normalized =
      if payment.respond_to?(:attributes)
        payment.attributes.symbolize_keys
      elsif payment.respond_to?(:to_h)
        payment.to_h.symbolize_keys
      else
        {}
      end

    {
      method: normalized[:method],
      amount: to_i_or_nil(normalized[:amount]),
      label: normalized[:label],
      source_text: normalized[:source_text],
      source_line_index: normalized[:source_line_index]
    }
  end

  def canonical_adjustments(adjustments, payments)
    grouped = adjustments.group_by { |adjustment| money_effect_key(adjustment) }
    canonical = grouped.flat_map do |key, entries|
      next entries if key.nil? || entries.one?

      [ preferred_adjustment(entries) ]
    end

    canonical.reject { |adjustment| voucher_payment_duplicate_adjustment?(adjustment, payments) }
  end

  def canonical_payments(payments, adjustments)
    payments.reject { |payment| payment_adjustment_duplicate_payment?(payment, adjustments) }
  end

  def preferred_adjustment(adjustments)
    adjustments.find { |adjustment| payment_adjustment?(adjustment) } || adjustments.first
  end

  def payment_adjustment_duplicate_payment?(payment, adjustments)
    payment_amount = to_i(payment[:amount])
    return false unless payment_amount.positive?

    adjustments.any? do |adjustment|
      next false unless payment_adjustment?(adjustment)
      next false unless to_i(adjustment[:amount]) == payment_amount

      same_money_effect?(payment, adjustment) || payment_adjustment_payment_text?(payment)
    end
  end

  def voucher_payment_duplicate_adjustment?(adjustment, payments)
    return false if payment_adjustment?(adjustment)
    return false unless to_i(adjustment[:amount]).positive?
    return false unless voucher_adjustment_text?(adjustment)

    payments.any? do |payment|
      voucher_payment_text?(payment) &&
        to_i(payment[:amount]) == to_i(adjustment[:amount]) &&
        same_money_effect?(payment, adjustment)
    end
  end

  def payment_adjustment?(adjustment)
    Amounts::AdjustmentClassifier.payment_adjustment?(adjustment)
  end

  def same_money_effect?(left, right)
    left_key = money_effect_key(left)
    left_key.present? && left_key == money_effect_key(right)
  end

  def money_effect_key(value)
    amount = to_i(fetch_value(value, :amount))
    return nil unless amount.positive?

    source_line_index = fetch_value(value, :source_line_index)
    return [ :line, source_line_index.to_i, amount ] if source_line_index.present?

    text = normalized_money_effect_text(value)
    return [ :text, text, amount ] if text.present?

    nil
  end

  def normalized_money_effect_text(value)
    [
      fetch_value(value, :source_text),
      fetch_value(value, :label),
      fetch_value(value, :method)
    ].compact.join(" ").unicode_normalize(:nfkc).downcase.gsub(/[[:space:]　,，¥￥\-−▲△:：]+/, "")
  end

  def payment_adjustment_payment_text?(payment)
    normalized_money_effect_text(payment).match?(/ポイント|point|キャッシュレス|cashless|還元|paymentdiscount|決済割引|支払割引/)
  end

  def voucher_payment_text?(payment)
    normalized_money_effect_text(payment).match?(/giftcard|giftcertificate|storecredit|voucher|商品券|金券|ギフト(?:カード|券)?|お買物券|買物券/)
  end

  def voucher_adjustment_text?(adjustment)
    normalized_money_effect_text(adjustment).match?(/giftcard|giftcertificate|storecredit|voucher|商品券|金券|ギフト(?:カード|券)?|お買物券|買物券/)
  end

  def default_adjustment_sign(kind)
    %w[service_charge late_night_charge delivery_fee bag_fee handling_fee].include?(kind.to_s) ? "surcharge" : "discount"
  end

  def adjustment_totals_for(receipt_tax_basis, rounding_mode: @tax_rounding_mode)
    @adjustment_totals_by_basis ||= {}
    key = [ receipt_tax_basis.to_s.to_sym, rounding_mode.to_s.to_sym ]
    @adjustment_totals_by_basis[key] ||= Amounts::AdjustmentTotalAggregator.new(
      adjustments: @adjustments,
      rounding_mode: rounding_mode,
      receipt_tax_basis: key.first
    ).call
  end

  def normalize_tax_detail(t)
    {
      amount: to_i_or_nil(fetch_value(t, :amount)),
      rate: fetch_value(t, :rate),
      net_amount: to_i_or_nil(fetch_value(t, :net_amount)),
      description: fetch_value(t, :description)
    }
  end

  def fetch_value(obj, key, default = nil)
    return default if obj.nil?

    if obj.is_a?(Hash)
      return obj[key] if obj.key?(key)
      return obj[key.to_s] if obj.key?(key.to_s)
      return default
    end

    obj.respond_to?(key) ? obj.public_send(key) : default
  end

  def to_i(v)
    Amounts::NumberParser.parse_amount(v)
  end

  def to_i_or_nil(value)
    Amounts::NumberParser.parse_amount_or_nil(value)
  end

  def to_decimal_or_nil(value)
    Amounts::NumberParser.parse_quantity_or_nil(value)
  end

  def normalize_rate(value)
    return BigDecimal("0") unless value_present?(value)

    rate = BigDecimal(value.to_s.delete("%"))
    rate > 1 ? rate / 100 : rate
  rescue ArgumentError
    BigDecimal("0")
  end

  def value_present?(value)
    !value.nil? && value != ""
  end
end
