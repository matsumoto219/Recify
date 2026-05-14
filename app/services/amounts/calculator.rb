# frozen_string_literal: true

module Amounts
  class Calculator
    def initialize(receipt:, items:, tax_details:, context: :analysis, rounding_mode: :floor)
      @receipt = receipt
      @items = items
      @tax_details = tax_details
      @context = normalize_context(context)
      @rounding_mode = Amounts::Rounding.normalize_rounding_mode(rounding_mode)
    end

    def call
      item_result = Amounts::ItemTotalAggregator.new(items: @items).call
      @items = item_result[:items]
      item_total = item_result[:total]
      tax_detail_total = calculate_tax_detail_total
      tax_detail_subtotal = calculate_tax_detail_subtotal
      fallback_tax_rate = resolve_fallback_tax_rate(item_total, tax_detail_total)
      external_tax = external_tax_details?(item_total, tax_detail_subtotal, tax_detail_total)
      tax_details_primary = tax_details_primary?(item_total, tax_detail_subtotal, tax_detail_total)

      if external_tax || tax_details_primary
        item_subtotal = tax_detail_subtotal
        item_tax_total = tax_detail_total
        subtotal = tax_detail_subtotal
        tax_total = tax_detail_total
        total = subtotal + tax_total
      else
        item_subtotal = calculate_item_subtotal(fallback_tax_rate)
        item_tax_total = item_total - item_subtotal

        total = resolve_total(item_total, nil, nil)
        subtotal = resolve_subtotal(item_total, item_subtotal, nil, total: total, tax_rate: fallback_tax_rate, tax_detail_subtotal: tax_detail_subtotal)
        tax_total = resolve_tax_total(item_tax_total, tax_detail_total, total: total, subtotal: subtotal)
        total = resolve_total(item_total, subtotal, tax_total)
      end

      tax_rate = resolve_tax_rate(fallback_tax_rate)

      {
        item_total: item_total,
        item_tax_total: item_tax_total,
        tax_detail_total: tax_detail_total,
        tax_total: tax_total,
        subtotal: subtotal,
        tax: tax_total,
        total: total,
        tax_rate: tax_rate,
        external_tax: external_tax,
        tax_details_primary: tax_details_primary,
        items: @items
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
    # tax_rate は 0.08 / 0.1 などの小数形式で扱う。
    def calculate_item_subtotal(fallback_tax_rate = BigDecimal("0"))
      total = calculate_item_total

      # 単一税率の場合は全体から逆算（端数ズレ防止）
      tax_rate = resolve_tax_rate(fallback_tax_rate)
      if tax_rate&.positive?
        tax = rounded_tax_from_gross(total, tax_rate)
        return total - tax
      end

      # 複数税率 or 不明な場合は従来ロジック
      @items.sum do |item|
        line_total = item_line_total(item)
        rate = normalize_tax_rate(item[:tax_rate])
        rate = fallback_tax_rate if rate <= 0

        next line_total if rate <= 0

        line_total - rounded_tax_from_gross(line_total, rate)
      end
    end

    def item_line_total(item)
      line_total = item[:line_total]
      return to_i(line_total) if line_total_present?(item)

      price = to_i(item[:price])
      quantity = to_i(item[:quantity])
      quantity = 1 if quantity <= 0

      price * quantity
    end

    # -----------------------------
    # Tax calculations
    # -----------------------------
    def calculate_tax_detail_total
      usable_tax_details.sum { |t| to_i(t[:amount]) }
    end

    def calculate_tax_detail_subtotal
      usable_tax_details.sum { |t| to_i(t[:net_amount]) }
    end

    def usable_tax_details
      details_with_net_amount = @tax_details.select { |tax_detail| to_i(tax_detail[:net_amount]).positive? }
      return details_with_net_amount if details_with_net_amount.present?

      @tax_details
    end

    def external_tax_details?(item_total, tax_detail_subtotal, tax_detail_total)
      return false if tax_detail_subtotal <= 0
      return false if tax_detail_total <= 0

      return true if external_tax_description?

      return false unless item_total.positive? && item_total == tax_detail_subtotal

      receipt_total = to_i(@receipt[:total_amount])
      receipt_total.positive? && receipt_total == item_total + tax_detail_total
    end

    def external_tax_description?
      @tax_details.any? do |tax_detail|
        description = tax_detail[:description].to_s
        description.match?(/外税|税別|消費税別|別途消費税/)
      end
    end

    def tax_details_primary?(item_total, tax_detail_subtotal, tax_detail_total)
      return false unless tax_detail_subtotal.positive?
      return false unless tax_detail_total.positive?
      return true unless item_total.positive?

      return false unless @context == :analysis

      tax_detail_rates = positive_tax_detail_rates
      item_tax_rates = positive_item_tax_rates

      tax_detail_rates.many? || item_tax_rates.empty?
    end

    # -----------------------------
    # Resolve helpers
    # -----------------------------
    def resolve_tax_total(item_tax_total, tax_detail_total, total: nil, subtotal: nil)
      return item_tax_total if item_tax_total.positive?
      return tax_detail_total if tax_detail_total.positive?

      receipt_tax_amount = to_i(@receipt[:tax_amount])
      return receipt_tax_amount if receipt_tax_amount.positive?

      # subtotal + tax_rate → tax を補完
      tax_rate = normalize_tax_rate(@receipt[:tax_rate])
      if subtotal.to_i.positive? && tax_rate.positive?
        return apply_rounding(BigDecimal(subtotal.to_s) * tax_rate)
      end

      # total fallback時に subtotal が無い（0）の場合は税額補完しない
      return 0 if subtotal.to_i <= 0

      calculated_tax = total.to_i - subtotal.to_i
      calculated_tax.positive? ? calculated_tax : 0
    end

    def resolve_subtotal(item_total, item_subtotal, tax_total, total: nil, tax_rate: BigDecimal("0"), tax_detail_subtotal: 0)
      return item_subtotal if item_subtotal.positive? && item_subtotal <= item_total

      receipt_subtotal = to_i(@receipt[:subtotal_amount])
      return receipt_subtotal if receipt_subtotal.positive?

      return tax_detail_subtotal if tax_detail_subtotal.to_i.positive?

      resolved_total = total.to_i
      if resolved_total.positive? && tax_rate.positive?
        return resolved_total - rounded_tax_from_gross(resolved_total, tax_rate)
      end

      subtotal = item_total - tax_total.to_i
      subtotal.positive? ? subtotal : item_total
    end

    def resolve_total(item_total, subtotal, tax_total)
      return item_total if item_total.positive?

      receipt_total = to_i(@receipt[:total_amount])
      return receipt_total if receipt_total.positive?

      subtotal.to_i + tax_total.to_i
    end

    def resolve_tax_rate(fallback_tax_rate = BigDecimal("0"))
      item_tax_rates = positive_item_tax_rates

      return item_tax_rates.first if item_tax_rates.one?
      return nil if item_tax_rates.many?

      tax_detail_rates = positive_tax_detail_rates

      return tax_detail_rates.first if tax_detail_rates.one?
      return fallback_tax_rate if fallback_tax_rate.positive?

      nil
    end

    def resolve_fallback_tax_rate(item_total, tax_detail_total)
      item_tax_rates = positive_item_tax_rates

      return item_tax_rates.first if item_tax_rates.one?
      return BigDecimal("0") if item_tax_rates.many?

      tax_detail_rates = positive_tax_detail_rates

      return tax_detail_rates.first if tax_detail_rates.one?
      return BigDecimal("0") if tax_detail_rates.many?

      receipt_tax_rate = normalize_tax_rate(@receipt[:tax_rate])
      return receipt_tax_rate if receipt_tax_rate.positive?

      infer_tax_rate_from_amounts(item_total, tax_detail_total)
    end

    def positive_item_tax_rates
      @items.filter_map do |item|
        tax_rate = normalize_tax_rate(item[:tax_rate])
        tax_rate.positive? ? tax_rate : nil
      end.uniq
    end

    def positive_tax_detail_rates
      @tax_details.filter_map do |tax_detail|
        tax_rate = normalize_tax_rate(tax_detail[:rate])
        tax_rate.positive? ? tax_rate : nil
      end.uniq
    end

    def infer_tax_rate_from_amounts(item_total, tax_detail_total)
      tax_amount = tax_detail_total.positive? ? tax_detail_total : to_i(@receipt[:tax_amount])
      receipt_subtotal = to_i(@receipt[:subtotal_amount])
      if tax_amount.positive? && receipt_subtotal.positive?
        return normalize_inferred_tax_rate(BigDecimal(tax_amount.to_s) / BigDecimal(receipt_subtotal.to_s))
      end

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
      tolerance = BigDecimal("0.03")

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

    def rounded_tax_from_gross(gross_total, tax_rate)
      Amounts::Rounding.apply_rounding(BigDecimal(gross_total.to_s) * tax_rate / (BigDecimal("1") + tax_rate), @rounding_mode)
    end

    def normalize_context(value)
      context = value.to_s.to_sym
      %i[analysis edit_save manual].include?(context) ? context : :analysis
    end

    def to_i(value)
      return 0 if blank?(value)

      value.to_i
    end

    def blank?(value)
      value.nil? || value == ""
    end

    def line_total_present?(item)
      flag = item[:amount_line_total_present]
      return flag if [ true, false ].include?(flag)

      !blank?(item[:line_total])
    end
  end
end
