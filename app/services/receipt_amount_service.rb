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
#   context: Symbol,
#   rounding_mode: { tax:, discount: },
#   needs_review: Boolean
# }
#
class ReceiptAmountService
  def self.call(receipt:, receipt_items:, receipt_tax_details:, receipt_adjustments: [], context:, rounding_mode: nil, tax_rounding_mode: nil, discount_rounding_mode: nil)
    new(
      receipt: receipt,
      receipt_items: receipt_items,
      receipt_tax_details: receipt_tax_details,
      receipt_adjustments: receipt_adjustments,
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

  def initialize(receipt:, receipt_items:, receipt_tax_details:, receipt_adjustments: [], context:, rounding_mode: nil, tax_rounding_mode: nil, discount_rounding_mode: nil)
    @receipt = normalize_receipt(receipt)
    @items = Array(receipt_items).map { |i| normalize_item(i) }
    @tax_details = Array(receipt_tax_details).map { |t| normalize_tax_detail(t) }
    @adjustments = Array(receipt_adjustments).map { |adjustment| normalize_adjustment(adjustment) }
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
    profile_estimation = applicable_calculation_profile(estimate_calculation_profile)
    active_profile = profile_estimation.applied_profile || {}
    active_tax_rounding_mode = active_profile[:tax_rounding_mode] || @tax_rounding_mode
    active_discount_rounding_mode = active_profile[:discount_rounding_mode] || @discount_rounding_mode
    active_receipt_tax_basis = active_profile[:receipt_tax_basis] || :auto
    active_item_amount_basis = active_profile[:item_amount_basis] || :line_total_as_recorded
    active_item_amount_basis_assignments = active_profile[:item_amount_basis_assignments]

    # --- 1) Calculator（純計算）
    calc = Amounts::Calculator.new(
      receipt: @receipt,
      items: @items,
      tax_details: @tax_details,
      adjustments: @adjustments,
      context: @context,
      tax_rounding_mode: active_tax_rounding_mode,
      discount_rounding_mode: active_discount_rounding_mode,
      receipt_tax_basis: active_receipt_tax_basis,
      item_amount_basis: active_item_amount_basis,
      item_amount_basis_assignments: active_item_amount_basis_assignments
    ).call

    # --- 2) Resolver（最終値決定）
    resolved = Amounts::Resolver.new(
      computed: calc,
      receipt: @receipt,
      context: @context,
      items: calc[:items] || @items,
      tax_details: @tax_details
    ).call

    # --- 3) TaxDetailAggregator（税率別集計）
    tax_details = if calc[:item_amount_basis] == :mixed_by_tax_rate_group && Array(calc[:tax_details]).present?
      Array(calc[:tax_details]).map do |tax_detail|
        {
          description: tax_detail[:description],
          rate: tax_detail[:rate],
          net_amount: tax_detail[:net_amount],
          amount: tax_detail[:amount]
        }
      end
    elsif calc[:external_tax] || calc[:tax_details_primary] || calc[:tax_detail_amount_basis] == :gross
      source_tax_details_for_external_tax.map do |t|
        {
          description: "#{(t[:rate].to_f * 100).to_i}%対象",
          rate: t[:rate],
          net_amount: t[:net_amount],
          amount: t[:amount]
        }
      end
    else
      Amounts::TaxDetailAggregator.new(
        items: calc[:items] || @items,
        adjustments: @adjustments,
        fallback_tax_rate: calc[:tax_rate],
        fallback_net_amount: resolved[:subtotal],
        fallback_tax_amount: resolved[:tax],
        rounding_mode: active_tax_rounding_mode,
        receipt_tax_basis: calc[:receipt_tax_basis]
      ).call
    end

    # --- 4) ConsistencyChecker（整合性チェック）
    inconsistencies = Amounts::ConsistencyChecker.new(
      computed: calc,
      resolved: resolved,
      item_total: calc[:adjusted_item_total] || calc[:item_total],
      tax_total: calc[:tax_total],
      receipt: @receipt,
      context: @context,
      items: calc[:items] || @items,
      item_count: @items.size,
      external_tax: calc[:external_tax],
      source_tax_details: @tax_details,
      generated_tax_details: tax_details,
      tax_details_primary: calc[:tax_details_primary],
      tax_rounding_mode: active_tax_rounding_mode
    ).call
    inconsistencies = (inconsistencies + profile_estimation.warnings + adjustment_inconsistencies).uniq

    mismatch_codes = build_mismatch_codes(inconsistencies)
    mismatch_messages = build_mismatch_messages(inconsistencies)

    # --- 5) ResultTemplate（出力整形）
    Amounts::ResultTemplate.build(
      computed: {
        subtotal: calc[:subtotal],
        tax: calc[:tax],
        total: calc[:total],
        tax_rate: calc[:tax_rate],
        receipt_tax_basis: calc[:receipt_tax_basis],
        item_amount_basis: calc[:item_amount_basis],
        tax_detail_amount_basis: calc[:tax_detail_amount_basis],
        adjustment_discount_total: calc[:adjustment_discount_total],
        adjustment_surcharge_total: calc[:adjustment_surcharge_total],
        payment_adjustment_total: calc[:payment_adjustment_total],
        adjustment_tax_rate_missing_total: calc.dig(:adjustment_summary, :tax_rate_missing_adjustment_total),
        adjusted_item_total: calc[:adjusted_item_total],
        items: calc[:items]
      },
      resolved: resolved,
      tax_details: tax_details,
      inconsistencies: inconsistencies,
      mismatch_codes: mismatch_codes,
      mismatch_messages: mismatch_messages,
      calculation_profile: profile_estimation.profile,
      calculation_profile_score: profile_estimation.score,
      calculation_profile_candidates: profile_estimation.candidates,
      context: @context,
      rounding_mode: {
        tax: active_tax_rounding_mode,
        discount: active_discount_rounding_mode
      }
    )
  end

  private

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
      tax_detail[:description].to_s.match?(/外税|税別|消費税別|別途消費税/)
    end
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
      next if adjustment[:kind] == "point_usage"

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

    Amounts::CalculationProfileResult.wrap(
      Amounts::CalculationProfileEstimator.new(
        receipt: @receipt,
        items: @items,
        tax_details: @tax_details,
        adjustments: @adjustments,
        context: @context,
        tax_rounding_modes: candidate_tax_rounding_modes,
        discount_rounding_modes: candidate_discount_rounding_modes
      ).call
    )
  end

  def candidate_tax_rounding_modes
    @tax_rounding_mode_explicit ? [ @tax_rounding_mode ] : Amounts::CalculationProfileEstimator::ROUNDING_MODES
  end

  def candidate_discount_rounding_modes
    @discount_rounding_mode_explicit ? [ @discount_rounding_mode ] : Amounts::CalculationProfileEstimator::ROUNDING_MODES
  end

  def empty_calculation_profile
    Amounts::CalculationProfileResult.new
  end

  def normalize_context(value)
    context = value.to_s.to_sym
    %i[analysis edit_save manual].include?(context) ? context : :analysis
  end

  def build_mismatch_codes(inconsistencies)
    Array(inconsistencies).filter_map do |inconsistency|
      Amounts::MismatchCodes.code(inconsistency.to_sym)
    end
  end

  def build_mismatch_messages(inconsistencies)
    Array(inconsistencies).filter_map do |inconsistency|
      I18n.t("enums.receipt_item.review_reason.#{inconsistency}", default: nil)
    end
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

    {
      price: to_i_or_nil(price),
      quantity: to_decimal_or_nil(quantity),
      original_line_total: to_i_or_nil(original_line_total),
      line_total: to_i_or_nil(line_total),
      discount_amount: to_i_or_nil(discount_amount),
      discount_rate: fetch_value(i, :discount_rate),
      quantity_unit: fetch_value(i, :quantity_unit),
      tax_rate: fetch_value(i, :tax_rate),
      amount_price_present: value_present?(price),
      amount_quantity_present: value_present?(quantity),
      amount_line_total_present: value_present?(line_total),
      amount_discount_amount_present: value_present?(discount_amount)
    }
  end

  def normalize_adjustment(adjustment)
    normalized = if adjustment.respond_to?(:attributes)
      adjustment.attributes.symbolize_keys
    elsif adjustment.respond_to?(:to_h)
      adjustment.to_h.symbolize_keys
    else
      {}
    end
    kind = normalized[:kind].to_s
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
      label: normalized[:label]
    }
  end

  def default_adjustment_sign(kind)
    %w[service_charge late_night_charge delivery_fee bag_fee handling_fee].include?(kind.to_s) ? "surcharge" : "discount"
  end

  def adjustment_inconsistencies
    return [] if @adjustments.blank?

    summary = adjustment_totals_for(:total_includes_tax)
    inconsistencies = []
    inconsistencies << :adjustment_uncertain if summary[:uncertain_adjustments].present?
    inconsistencies << :adjustment_tax_rate_missing if summary[:tax_rate_missing_adjustment_total].to_i.positive?
    inconsistencies
  end

  def adjustment_totals_for(receipt_tax_basis)
    @adjustment_totals_by_basis ||= {}
    basis = receipt_tax_basis.to_s.to_sym
    @adjustment_totals_by_basis[basis] ||= Amounts::AdjustmentTotalAggregator.new(
      adjustments: @adjustments,
      items: @items,
      rounding_mode: @tax_rounding_mode,
      receipt_tax_basis: basis
    ).call
  end

  def source_tax_details_for_external_tax
    details_with_net_amount = @tax_details.select { |tax_detail| to_i(tax_detail[:net_amount]).positive? }
    return details_with_net_amount if details_with_net_amount.present?

    @tax_details
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

    if obj.respond_to?(key)
      obj.public_send(key)
    elsif obj.is_a?(Hash)
      obj[key] || obj[key.to_s] || default
    else
      default
    end
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
