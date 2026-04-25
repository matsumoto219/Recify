# frozen_string_literal: true

module Amounts
  class Calculator
    def initialize(receipt:, items:, tax_details:)
      @receipt = receipt
      @items = items
      @tax_details = tax_details
    end

    def call
      item_total = calculate_item_total
      tax_detail_total = calculate_tax_detail_total
      fallback_tax_rate = resolve_fallback_tax_rate(item_total, tax_detail_total)
      item_subtotal = calculate_item_subtotal(fallback_tax_rate)
      item_tax_total = item_total - item_subtotal

      tax_total = resolve_tax_total(item_tax_total, tax_detail_total)
      subtotal = resolve_subtotal(item_total, item_subtotal, tax_total)
      total = resolve_total(item_total, subtotal, tax_total)
      tax_rate = resolve_tax_rate(fallback_tax_rate)

      {
        item_total: item_total,
        item_tax_total: item_tax_total,
        tax_detail_total: tax_detail_total,
        tax_total: tax_total,
        subtotal: subtotal,
        tax: tax_total,
        total: total,
        tax_rate: tax_rate
      }
    end

    private

    # -----------------------------
    # Item calculations
    # -----------------------------
    # price / line_total は税込金額として扱う。
    def calculate_item_total
      @items.sum { |item| item_line_total(item) }
    end

    # 明細ごとの税込金額から税抜金額を逆算する。
    # tax_rate は 0.08 / 0.1 形式で保存されている前提。
    def calculate_item_subtotal(fallback_tax_rate = BigDecimal("0"))
      @items.sum do |item|
        line_total = item_line_total(item)
        tax_rate = normalize_tax_rate(item[:tax_rate])
        tax_rate = fallback_tax_rate if tax_rate <= 0

        next line_total if tax_rate <= 0

        (BigDecimal(line_total.to_s) / (BigDecimal("1") + tax_rate)).floor
      end
    end

    def item_line_total(item)
      line_total = to_i(item[:line_total])
      return line_total if line_total.positive?

      price = to_i(item[:price])
      quantity = to_i(item[:quantity])
      quantity = 1 if quantity <= 0

      price * quantity
    end

    # -----------------------------
    # Tax calculations
    # -----------------------------
    def calculate_tax_detail_total
      @tax_details.sum { |t| to_i(t[:amount]) }
    end

    # -----------------------------
    # Resolve helpers
    # -----------------------------
    def resolve_tax_total(item_tax_total, tax_detail_total)
      return item_tax_total if item_tax_total.positive?
      return tax_detail_total if tax_detail_total.positive?

      receipt_tax_amount = to_i(@receipt[:tax_amount])
      receipt_tax_amount.positive? ? receipt_tax_amount : 0
    end

    def resolve_subtotal(item_total, item_subtotal, tax_total)
      return item_subtotal if item_subtotal.positive? && item_subtotal <= item_total

      receipt_subtotal = to_i(@receipt[:subtotal_amount])
      return receipt_subtotal if receipt_subtotal.positive?

      subtotal = item_total - tax_total
      subtotal.positive? ? subtotal : item_total
    end

    def resolve_total(item_total, subtotal, tax_total)
      return item_total if item_total.positive?

      receipt_total = to_i(@receipt[:total_amount])
      return receipt_total if receipt_total.positive?

      subtotal.to_i + tax_total.to_i
    end

    def resolve_tax_rate(fallback_tax_rate = BigDecimal("0"))
      item_tax_rates = @items.filter_map do |item|
        tax_rate = normalize_tax_rate(item[:tax_rate])
        tax_rate.positive? ? tax_rate : nil
      end.uniq

      return item_tax_rates.first if item_tax_rates.one?
      return nil if item_tax_rates.many?

      tax_detail_rates = @tax_details.filter_map do |tax_detail|
        tax_rate = normalize_tax_rate(tax_detail[:rate])
        tax_rate.positive? ? tax_rate : nil
      end.uniq

      return tax_detail_rates.first if tax_detail_rates.one?
      return fallback_tax_rate if fallback_tax_rate.positive?

      nil
    end

    def resolve_fallback_tax_rate(item_total, tax_detail_total)
      item_tax_rates = @items.filter_map do |item|
        tax_rate = normalize_tax_rate(item[:tax_rate])
        tax_rate.positive? ? tax_rate : nil
      end.uniq

      return item_tax_rates.first if item_tax_rates.one?
      return BigDecimal("0") if item_tax_rates.many?

      tax_detail_rates = @tax_details.filter_map do |tax_detail|
        tax_rate = normalize_tax_rate(tax_detail[:rate])
        tax_rate.positive? ? tax_rate : nil
      end.uniq

      return tax_detail_rates.first if tax_detail_rates.one?
      return BigDecimal("0") if tax_detail_rates.many?

      infer_tax_rate_from_amounts(item_total, tax_detail_total)
    end

    def infer_tax_rate_from_amounts(item_total, tax_detail_total)
      tax_amount = tax_detail_total.positive? ? tax_detail_total : to_i(@receipt[:tax_amount])
      total_amount = item_total.positive? ? item_total : to_i(@receipt[:total_amount])
      return BigDecimal("0") if tax_amount <= 0
      return BigDecimal("0") if total_amount <= tax_amount

      net_amount = total_amount - tax_amount
      raw_rate = BigDecimal(tax_amount.to_s) / BigDecimal(net_amount.to_s)

      normalize_inferred_tax_rate(raw_rate)
    end

    def normalize_inferred_tax_rate(rate)
      return BigDecimal("0") if rate <= 0

      percentage = rate * 100

      # config想定（将来外出し）
      step = BigDecimal("0.5")
      tolerance = BigDecimal("0.02")

      # 0.5刻みに丸め
      rounded = (percentage / step).round * step

      # 許容誤差チェック（例: ±0.02%）
      return BigDecimal("0") if (percentage - rounded).abs > tolerance

      BigDecimal(rounded.to_s) / 100
    end

    def normalize_tax_rate(value)
      return BigDecimal("0") if blank?(value)

      tax_rate = BigDecimal(value.to_s)
      tax_rate > 1 ? tax_rate / 100 : tax_rate
    rescue ArgumentError
      BigDecimal("0")
    end

    def to_i(value)
      return 0 if blank?(value)

      value.to_i
    end

    def blank?(value)
      value.nil? || value == ""
    end
  end
end
