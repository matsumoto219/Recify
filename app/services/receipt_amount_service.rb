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
#   computed: { subtotal:, tax:, total: },
#   resolved: { subtotal:, tax:, total:, tax_rate: },
#   tax_details: Array<Hash>,
#   inconsistencies: Array<Symbol>,
#   needs_review: Boolean
# }
#
class ReceiptAmountService
  def self.call(receipt:, receipt_items:, receipt_tax_details:, context:)
    new(
      receipt: receipt,
      receipt_items: receipt_items,
      receipt_tax_details: receipt_tax_details,
      context: context
    ).call
  end

  def initialize(receipt:, receipt_items:, receipt_tax_details:, context:)
    @receipt = normalize_receipt(receipt)
    @items = Array(receipt_items).map { |i| normalize_item(i) }
    @tax_details = Array(receipt_tax_details).map { |t| normalize_tax_detail(t) }
    @context = context # :analysis / :edit_save / :manual
  end

  def call
    # --- 1) Calculator（純計算）
    calc = Amounts::Calculator.new(
      receipt: @receipt,
      items: @items,
      tax_details: @tax_details
    ).call

    # --- 2) Resolver（最終値決定）
    resolved = Amounts::Resolver.new(
      computed: calc,
      receipt: @receipt,
      context: @context
    ).call

    # --- 3) ConsistencyChecker（整合性チェック）
    inconsistencies = Amounts::ConsistencyChecker.new(
      computed: calc,
      resolved: resolved,
      item_total: calc[:item_total],
      tax_total: calc[:tax_total],
      receipt: @receipt,
      context: @context
    ).call

    # --- 4) TaxDetailAggregator（税率別集計）
    tax_details = Amounts::TaxDetailAggregator.new(
      items: @items,
      fallback_tax_rate: calc[:tax_rate]
    ).call

    # --- 5) ResultTemplate（出力整形）
    Amounts::ResultTemplate.build(
      computed: {
        subtotal: calc[:subtotal],
        tax: calc[:tax],
        total: calc[:total]
      },
      resolved: resolved,
      tax_details: tax_details,
      inconsistencies: inconsistencies
    )
  end

  private

  # -----------------------------
  # Normalizers (accept Hash/AR)
  # -----------------------------
  def normalize_receipt(r)
    {
      total_amount: fetch_value(r, :total_amount),
      subtotal_amount: fetch_value(r, :subtotal_amount),
      tax_amount: fetch_value(r, :tax_amount)
    }
  end

  def normalize_item(i)
    {
      price: to_i(fetch_value(i, :price)),
      quantity: to_i(fetch_value(i, :quantity, 1)),
      line_total: to_i(fetch_value(i, :line_total)),
      tax_rate: fetch_value(i, :tax_rate)
    }
  end

  def normalize_tax_detail(t)
    {
      amount: to_i(fetch_value(t, :amount)),
      rate: fetch_value(t, :rate),
      net_amount: to_i(fetch_value(t, :net_amount))
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
    return 0 if v.nil?
    return v if v.is_a?(Integer)
    v.to_f.round
  rescue StandardError
    0
  end
end
