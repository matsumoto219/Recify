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
#
# Output:
# {
#   computed: { subtotal:, tax:, total:, tax_rate: },
#   resolved: { subtotal:, tax:, total:, tax_rate: },
#   tax_details: Array<Hash>,
#   inconsistencies: Array<Symbol>,
#   mismatch_codes: Array<String>,
#   mismatch_messages: Array<String>,
#   needs_review: Boolean
# }
#
class ReceiptAmountService
  def self.call(receipt:, receipt_items:, receipt_tax_details:, context:, rounding_mode: nil, tax_rounding_mode: nil, discount_rounding_mode: nil)
    new(
      receipt: receipt,
      receipt_items: receipt_items,
      receipt_tax_details: receipt_tax_details,
      context: context,
      rounding_mode: rounding_mode,
      tax_rounding_mode: tax_rounding_mode,
      discount_rounding_mode: discount_rounding_mode
    ).call
  end

  def initialize(receipt:, receipt_items:, receipt_tax_details:, context:, rounding_mode: nil, tax_rounding_mode: nil, discount_rounding_mode: nil)
    @receipt = normalize_receipt(receipt)
    @items = Array(receipt_items).map { |i| normalize_item(i) }
    @tax_details = Array(receipt_tax_details).map { |t| normalize_tax_detail(t) }
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
    active_profile = profile_estimation[:applied_profile] || {}
    active_tax_rounding_mode = active_profile[:tax_rounding_mode] || @tax_rounding_mode
    active_discount_rounding_mode = active_profile[:discount_rounding_mode] || @discount_rounding_mode
    active_tax_basis = active_profile[:tax_basis] || :auto

    # --- 1) Calculator（純計算）
    calc = Amounts::Calculator.new(
      receipt: @receipt,
      items: @items,
      tax_details: @tax_details,
      context: @context,
      tax_rounding_mode: active_tax_rounding_mode,
      discount_rounding_mode: active_discount_rounding_mode,
      tax_basis: active_tax_basis
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
    tax_details = if calc[:external_tax] || calc[:tax_details_primary]
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
        fallback_tax_rate: calc[:tax_rate],
        fallback_net_amount: resolved[:subtotal],
        fallback_tax_amount: resolved[:tax],
        rounding_mode: active_tax_rounding_mode
      ).call
    end

    # --- 4) ConsistencyChecker（整合性チェック）
    inconsistencies = Amounts::ConsistencyChecker.new(
      computed: calc,
      resolved: resolved,
      item_total: calc[:item_total],
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

    mismatch_codes = build_mismatch_codes(inconsistencies)
    mismatch_messages = build_mismatch_messages(inconsistencies)

    # --- 5) ResultTemplate（出力整形）
    Amounts::ResultTemplate.build(
      computed: {
        subtotal: calc[:subtotal],
        tax: calc[:tax],
        total: calc[:total],
        tax_rate: calc[:tax_rate],
        items: calc[:items]
      },
      resolved: resolved,
      tax_details: tax_details,
      inconsistencies: inconsistencies,
      mismatch_codes: mismatch_codes,
      mismatch_messages: mismatch_messages,
      calculation_profile: profile_estimation[:applied_profile],
      calculation_profile_score: profile_estimation[:score],
      calculation_profile_candidates: profile_estimation[:candidates]
    )
  end

  private

  def applicable_calculation_profile(profile_estimation)
    profile_estimation.merge(
      applied_profile: profile_estimation[:score].to_i.zero? ? profile_estimation[:profile] : nil
    )
  end

  def estimate_calculation_profile
    return empty_calculation_profile unless @context == :analysis

    Amounts::CalculationProfileEstimator.new(
      receipt: @receipt,
      items: @items,
      tax_details: @tax_details,
      context: @context,
      tax_rounding_modes: candidate_tax_rounding_modes,
      discount_rounding_modes: candidate_discount_rounding_modes
    ).call
  end

  def candidate_tax_rounding_modes
    @tax_rounding_mode_explicit ? [ @tax_rounding_mode ] : Amounts::CalculationProfileEstimator::ROUNDING_MODES
  end

  def candidate_discount_rounding_modes
    @discount_rounding_mode_explicit ? [ @discount_rounding_mode ] : Amounts::CalculationProfileEstimator::ROUNDING_MODES
  end

  def empty_calculation_profile
    {
      profile: nil,
      score: nil,
      candidates: []
    }
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

    {
      price: to_i_or_nil(price),
      quantity: to_decimal_or_nil(quantity),
      original_line_total: to_i_or_nil(original_line_total),
      line_total: to_i_or_nil(line_total),
      discount_amount: to_i(fetch_value(i, :discount_amount)),
      discount_rate: fetch_value(i, :discount_rate),
      quantity_unit: fetch_value(i, :quantity_unit),
      tax_rate: fetch_value(i, :tax_rate),
      amount_price_present: value_present?(price),
      amount_quantity_present: value_present?(quantity),
      amount_line_total_present: value_present?(line_total)
    }
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

  def value_present?(value)
    !value.nil? && value != ""
  end
end
