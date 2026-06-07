# frozen_string_literal: true

module Amounts
  class Calculator
    def initialize(receipt:, items:, tax_details:, adjustments: [], context: :analysis, rounding_mode: Amounts::Rounding::TAX_DEFAULT_MODE, tax_rounding_mode: nil, discount_rounding_mode: Amounts::Rounding::DISCOUNT_DEFAULT_MODE, receipt_tax_basis: :auto, item_amount_basis: :line_total_as_recorded, item_amount_basis_assignments: nil)
      @receipt = receipt
      @items = items
      @tax_details = tax_details
      @adjustments = Array(adjustments)
      @context = normalize_context(context)
      @receipt_tax_basis = normalize_receipt_tax_basis(receipt_tax_basis)
      @item_amount_basis = normalize_item_amount_basis(item_amount_basis)
      @item_amount_basis_assignments = normalize_item_amount_basis_assignments(item_amount_basis_assignments)
      @tax_rounding_mode = Amounts::Rounding.normalize_rounding_mode(
        tax_rounding_mode || rounding_mode || Amounts::Rounding::TAX_DEFAULT_MODE
      )
      @discount_rounding_mode = Amounts::Rounding.normalize_rounding_mode(
        discount_rounding_mode || Amounts::Rounding::DISCOUNT_DEFAULT_MODE
      )
    end

    def call
      item_result = Amounts::ItemTotalAggregator.new(
        items: @items,
        context: @context,
        discount_rounding_mode: @discount_rounding_mode
      ).call
      @items = item_result[:items]
      item_total = item_result[:total]
      tax_detail_total = calculate_tax_detail_total
      tax_detail_subtotal = calculate_tax_detail_subtotal
      detection_adjustment_summary = adjustment_summary_for(:total_includes_tax)
      adjusted_item_total_for_detection = [ item_total + detection_adjustment_summary[:receipt_total_delta], 0 ].max
      tax_detail_amount_basis = resolve_tax_detail_amount_basis(adjusted_item_total_for_detection, tax_detail_subtotal, tax_detail_total)
      fallback_tax_rate = resolve_fallback_tax_rate(adjusted_item_total_for_detection, tax_detail_total)

      if @item_amount_basis == :mixed_by_tax_rate_group && @item_amount_basis_assignments.present?
        amounts = mixed_assignment_amounts
        tax_details = mixed_assignment_tax_details
        tax_rates = tax_details.filter_map { |tax_detail| normalize_tax_rate(tax_detail[:rate]) }.uniq
        adjustment_summary = adjustment_summary_for(:total_includes_tax)

        return {
          item_total: item_total,
          adjusted_item_total: [ amounts[:total] + adjustment_summary[:total_delta], 0 ].max,
          item_tax_total: [ amounts[:tax] + adjustment_summary[:tax_delta], 0 ].max,
          tax_detail_total: amounts[:tax],
          tax_total: [ amounts[:tax] + adjustment_summary[:tax_delta], 0 ].max,
          subtotal: [ amounts[:subtotal] + adjustment_summary[:subtotal_delta], 0 ].max,
          tax: [ amounts[:tax] + adjustment_summary[:tax_delta], 0 ].max,
          total: [ amounts[:total] + adjustment_summary[:total_delta], 0 ].max,
          tax_rate: tax_rates.one? ? tax_rates.first : nil,
          external_tax: false,
          tax_details_primary: false,
          receipt_tax_basis: @receipt_tax_basis == :tax_added_to_subtotal ? :tax_added_to_subtotal : :total_includes_tax,
          item_amount_basis: :mixed_by_tax_rate_group,
          tax_detail_amount_basis: tax_detail_amount_basis,
          item_amount_basis_assignments: @item_amount_basis_assignments,
          adjustment_summary: adjustment_summary,
          adjustment_discount_total: adjustment_summary[:discount_total],
          adjustment_surcharge_total: adjustment_summary[:surcharge_total],
          payment_adjustment_total: adjustment_summary[:payment_adjustment_total],
          tax_details: tax_details,
          items: @items
        }
      end

      if @item_amount_basis == :line_total_as_net
        adjustment_summary = adjustment_summary_for(:tax_added_to_subtotal)
        subtotal = [ item_total + adjustment_summary[:subtotal_delta], 0 ].max
        tax_total = [ calculate_tax_excluded_item_tax_total(fallback_tax_rate) + adjustment_summary[:tax_delta], 0 ].max
        tax_rate = resolve_tax_rate(fallback_tax_rate)

        return {
          item_total: item_total,
          adjusted_item_total: subtotal,
          item_tax_total: tax_total,
          tax_detail_total: tax_detail_total,
          tax_total: tax_total,
          subtotal: subtotal,
          tax: tax_total,
          total: subtotal + tax_total,
          tax_rate: tax_rate,
          external_tax: true,
          tax_details_primary: false,
          receipt_tax_basis: :tax_added_to_subtotal,
          item_amount_basis: :line_total_as_net,
          tax_detail_amount_basis: :net,
          adjustment_summary: adjustment_summary,
          adjustment_discount_total: adjustment_summary[:discount_total],
          adjustment_surcharge_total: adjustment_summary[:surcharge_total],
          payment_adjustment_total: adjustment_summary[:payment_adjustment_total],
          items: @items
        }
      end

      external_tax = resolve_external_tax(adjusted_item_total_for_detection, tax_detail_subtotal, tax_detail_total)
      external_tax = false if tax_detail_amount_basis == :gross
      tax_details_primary = resolve_tax_details_primary(adjusted_item_total_for_detection, tax_detail_subtotal, tax_detail_total)
      tax_details_primary = false if tax_detail_amount_basis == :gross
      adjustment_summary = adjustment_summary_for(external_tax ? :tax_added_to_subtotal : :total_includes_tax)

      if tax_detail_amount_basis == :gross
        item_subtotal = adjusted_item_total_for_detection
        item_tax_total = tax_detail_total
        subtotal = adjusted_item_total_for_detection
        tax_total = tax_detail_total
        total = adjusted_item_total_for_detection
      elsif external_tax || tax_details_primary
        item_subtotal = tax_detail_subtotal
        item_tax_total = tax_detail_total
        subtotal = tax_detail_subtotal
        tax_total = tax_detail_total
        total = subtotal + tax_total
      else
        item_subtotal = calculate_item_subtotal(fallback_tax_rate)
        item_tax_total = item_total - item_subtotal
        item_subtotal = [ item_subtotal + adjustment_summary[:subtotal_delta], 0 ].max
        item_tax_total = [ item_tax_total + adjustment_summary[:tax_delta], 0 ].max

        adjusted_total = [ item_total + adjustment_summary[:total_delta], 0 ].max
        total = resolve_total(adjusted_total, nil, nil)
        subtotal = resolve_subtotal(adjusted_total, item_subtotal, nil, total: total, tax_rate: fallback_tax_rate, tax_detail_subtotal: tax_detail_subtotal)
        tax_total = resolve_tax_total(item_tax_total, tax_detail_total, total: total, subtotal: subtotal)
        total = resolve_total(adjusted_total, subtotal, tax_total)
      end

      tax_rate = resolve_tax_rate(fallback_tax_rate)

      {
        item_total: item_total,
        adjusted_item_total: [ item_total + adjustment_summary[:receipt_total_delta], 0 ].max,
        item_tax_total: item_tax_total,
        tax_detail_total: tax_detail_total,
        tax_total: tax_total,
        subtotal: subtotal,
        tax: tax_total,
        total: total,
        tax_rate: tax_rate,
        external_tax: external_tax,
        tax_details_primary: tax_details_primary,
        receipt_tax_basis: external_tax ? :tax_added_to_subtotal : :total_includes_tax,
        item_amount_basis: :line_total_as_recorded,
        tax_detail_amount_basis: tax_detail_amount_basis,
        adjustment_summary: adjustment_summary,
        adjustment_discount_total: adjustment_summary[:discount_total],
        adjustment_surcharge_total: adjustment_summary[:surcharge_total],
        payment_adjustment_total: adjustment_summary[:payment_adjustment_total],
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

    def calculate_tax_excluded_item_tax_total(fallback_tax_rate = BigDecimal("0"))
      net_totals = @items.each_with_object({}) do |item, groups|
        line_total = item_line_total(item)
        next if line_total <= 0

        rate = normalize_tax_rate(item[:tax_rate])
        rate = fallback_tax_rate if rate <= 0
        next if rate <= 0

        groups[rate] ||= 0
        groups[rate] += line_total
      end

      net_totals.sum do |rate, net_total|
        Amounts::Rounding.apply_rounding(BigDecimal(net_total.to_s) * rate, @tax_rounding_mode)
      end
    end

    def mixed_assignment_amounts
      {
        subtotal: @item_amount_basis_assignments.sum { |assignment| to_i(assignment[:net_amount]) },
        tax: @item_amount_basis_assignments.sum { |assignment| to_i(assignment[:tax_amount]) },
        total: @item_amount_basis_assignments.sum { |assignment| to_i(assignment[:gross_amount]) }
      }
    end

    def mixed_assignment_tax_details
      @item_amount_basis_assignments.filter_map do |assignment|
        rate = normalize_tax_rate(assignment[:tax_rate])
        next if rate <= 0

        {
          description: "#{(rate * 100).to_i}%対象",
          rate: rate,
          net_amount: to_i(assignment[:net_amount]),
          amount: to_i(assignment[:tax_amount])
        }
      end
    end

    def item_line_total(item)
      line_total = item[:line_total]
      return to_i(line_total) if line_total_present?(item)
      return 0 unless countable_quantity_unit?(item[:quantity_unit])

      price = to_amount_decimal(item[:price])
      quantity = to_decimal(item[:quantity])
      quantity = BigDecimal("1") if quantity <= 0

      round_amount(price * quantity)
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

    def resolve_external_tax(item_total, tax_detail_subtotal, tax_detail_total)
      case @receipt_tax_basis
      when :tax_added_to_subtotal
        tax_detail_subtotal.positive? && tax_detail_total.positive?
      when :total_includes_tax
        false
      else
        external_tax_details?(item_total, tax_detail_subtotal, tax_detail_total)
      end
    end

    def resolve_tax_details_primary(item_total, tax_detail_subtotal, tax_detail_total)
      return false unless @receipt_tax_basis == :auto

      tax_details_primary?(item_total, tax_detail_subtotal, tax_detail_total)
    end

    def resolve_tax_detail_amount_basis(adjusted_item_total, tax_detail_subtotal, tax_detail_total)
      return :unknown unless @receipt_tax_basis == :auto || @receipt_tax_basis == :total_includes_tax
      return :unknown unless adjusted_item_total.to_i.positive?
      return :unknown unless tax_detail_subtotal.to_i.positive?
      return :unknown unless tax_detail_total.to_i.positive?
      return :net if external_tax_description?

      receipt_total = to_i(@receipt[:total_amount])
      return :net if receipt_total.positive? && receipt_total == tax_detail_subtotal + tax_detail_total

      return :unknown unless tax_detail_subtotal == adjusted_item_total
      return :unknown unless gross_tax_detail_amounts_match?
      return :unknown unless gross_tax_detail_receipt_evidence?(adjusted_item_total)

      :gross
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
      return false if tax_detail_subtotal + tax_detail_total < item_total

      return false unless @context == :analysis

      tax_detail_rates = positive_tax_detail_rates
      item_tax_rates = positive_item_tax_rates

      tax_detail_rates.many? || item_tax_rates.empty?
    end

    def gross_tax_detail_amounts_match?
      complete_tax_details = @tax_details.select do |tax_detail|
        normalize_tax_rate(tax_detail[:rate]).positive? &&
          to_i(tax_detail[:net_amount]).positive? &&
          to_i(tax_detail[:amount]).positive?
      end
      return false if complete_tax_details.blank?

      complete_tax_details.all? do |tax_detail|
        rate = normalize_tax_rate(tax_detail[:rate])
        gross = to_i(tax_detail[:net_amount])
        printed_tax = to_i(tax_detail[:amount])

        %i[floor round ceil].any? do |rounding_mode|
          rounded_tax_from_gross(gross, rate, rounding_mode) == printed_tax
        end
      end
    end

    def gross_tax_detail_receipt_evidence?(adjusted_item_total)
      receipt_total = to_i(@receipt[:total_amount])
      receipt_subtotal = to_i(@receipt[:subtotal_amount])

      return true if receipt_total.positive? && receipt_total == adjusted_item_total
      return true if receipt_subtotal.positive? && receipt_subtotal == adjusted_item_total

      false
    end

    # -----------------------------
    # Resolve helpers
    # -----------------------------
    def resolve_tax_total(item_tax_total, tax_detail_total, total: nil, subtotal: nil)
      return item_tax_total if item_tax_total.positive?
      return tax_detail_total if tax_detail_total.positive?
      return 0 if manual_zero_item_total_authoritative?(to_i(total))

      receipt_tax_amount = to_i(@receipt[:tax_amount])
      return receipt_tax_amount if receipt_tax_amount.positive?

      # subtotal + tax_rate → tax を補完
      tax_rate = normalize_tax_rate(@receipt[:tax_rate])
      if to_i(subtotal).positive? && tax_rate.positive?
        return Amounts::Rounding.apply_rounding(BigDecimal(subtotal.to_s) * tax_rate, @tax_rounding_mode)
      end

      # total fallback時に subtotal が無い（0）の場合は税額補完しない
      return 0 if to_i(subtotal) <= 0

      calculated_tax = to_i(total) - to_i(subtotal)
      calculated_tax.positive? ? calculated_tax : 0
    end

    def resolve_subtotal(item_total, item_subtotal, tax_total, total: nil, tax_rate: BigDecimal("0"), tax_detail_subtotal: 0)
      return item_subtotal if item_subtotal.positive? && item_subtotal <= item_total
      return item_subtotal if manual_zero_item_total_authoritative?(item_total)

      receipt_subtotal = to_i(@receipt[:subtotal_amount])
      return receipt_subtotal if receipt_subtotal.positive?

      return tax_detail_subtotal if to_i(tax_detail_subtotal).positive?

      resolved_total = to_i(total)
      if resolved_total.positive? && tax_rate.positive?
        return resolved_total - rounded_tax_from_gross(resolved_total, tax_rate)
      end

      subtotal = item_total - to_i(tax_total)
      subtotal.positive? ? subtotal : item_total
    end

    def resolve_total(item_total, subtotal, tax_total)
      return item_total if item_total.positive?
      return item_total if manual_zero_item_total_authoritative?(item_total)

      receipt_total = to_i(@receipt[:total_amount])
      return receipt_total if receipt_total.positive?

      to_i(subtotal) + to_i(tax_total)
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

    def adjustment_summary_for(receipt_tax_basis)
      @adjustment_summary_by_basis ||= {}
      basis = normalize_adjustment_receipt_tax_basis(receipt_tax_basis)

      @adjustment_summary_by_basis[basis] ||= Amounts::AdjustmentTotalAggregator.new(
        adjustments: @adjustments,
        rounding_mode: @tax_rounding_mode,
        receipt_tax_basis: basis
      ).call
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

      # TODO: 国別税制対応時に rounding_step / tolerance をconfig化する。
      # 現状は日本向けの固定値で推定する。詳細はroadmapを参照。
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

    def rounded_tax_from_gross(gross_total, tax_rate, rounding_mode = @tax_rounding_mode)
      Amounts::Rounding.apply_rounding(BigDecimal(gross_total.to_s) * tax_rate / (BigDecimal("1") + tax_rate), rounding_mode)
    end

    def normalize_context(value)
      context = value.to_s.to_sym
      %i[analysis edit_save manual].include?(context) ? context : :analysis
    end

    def normalize_receipt_tax_basis(value)
      basis = value.to_s.to_sym
      %i[auto total_includes_tax tax_added_to_subtotal].include?(basis) ? basis : :auto
    end

    def normalize_adjustment_receipt_tax_basis(value)
      basis = value.to_s.to_sym
      %i[total_includes_tax tax_added_to_subtotal].include?(basis) ? basis : :total_includes_tax
    end

    def normalize_item_amount_basis(value)
      basis = value.to_s.to_sym
      %i[line_total_as_recorded line_total_as_net mixed_by_tax_rate_group].include?(basis) ? basis : :line_total_as_recorded
    end

    def normalize_item_amount_basis_assignments(assignments)
      Array(assignments).filter_map do |assignment|
        basis = assignment[:basis].to_s.to_sym
        next unless %i[tax_included tax_excluded non_taxable].include?(basis)

        {
          tax_rate: normalize_tax_rate(assignment[:tax_rate]),
          basis: basis,
          net_amount: to_i(assignment[:net_amount]),
          tax_amount: to_i(assignment[:tax_amount]),
          gross_amount: to_i(assignment[:gross_amount])
        }
      end
    end

    def to_i(value)
      Amounts::NumberParser.parse_amount(value)
    end

    def to_decimal(value)
      Amounts::NumberParser.parse_quantity(value)
    end

    def to_amount_decimal(value)
      BigDecimal(to_i(value).to_s)
    end

    def round_amount(value)
      BigDecimal(value.to_s).round(0).to_i
    end

    def blank?(value)
      value.nil? || value == ""
    end

    def line_total_present?(item)
      flag = item[:amount_line_total_present]
      return flag if [ true, false ].include?(flag)

      !blank?(item[:line_total])
    end

    def countable_quantity_unit?(unit)
      ReceiptItem::COUNTABLE_QUANTITY_UNITS.include?(unit.to_s.strip)
    end

    def manual_input_context?
      %i[edit_save manual].include?(@context)
    end

    def manual_zero_item_total_authoritative?(item_total)
      manual_input_context? &&
        to_i(item_total).zero? &&
        @items.any? { |item| explicit_zero_amount_item?(item) }
    end

    def explicit_zero_amount_item?(item)
      explicit_zero_line_total?(item) || explicit_zero_price_total?(item)
    end

    def explicit_zero_line_total?(item)
      line_total_present?(item) && to_i(item[:line_total]).zero?
    end

    def explicit_zero_price_total?(item)
      value_was_present?(item, :price) && to_i(item[:price]).zero?
    end

    def value_was_present?(item, key)
      flag = item[:"amount_#{key}_present"]
      return flag if [ true, false ].include?(flag)

      !blank?(item[key])
    end
  end
end
