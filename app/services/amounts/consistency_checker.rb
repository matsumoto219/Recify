# frozen_string_literal: true

module Amounts
  class ConsistencyChecker
    def initialize(computed:, resolved:, item_total:, tax_total:, receipt:, context:, items: [], item_count: 0, external_tax: false, source_tax_details: [], generated_tax_details: [], tax_details_primary: false, rounding_mode: Amounts::Rounding::TAX_DEFAULT_MODE, tax_rounding_mode: nil)
      @computed = computed
      @resolved = resolved
      @item_total = item_total
      @tax_total = tax_total
      @receipt = receipt
      @context = context
      @items = Array(items)
      @item_count = item_count.to_i
      @external_tax = external_tax
      @source_tax_details = Array(source_tax_details)
      @generated_tax_details = Array(generated_tax_details)
      @tax_details_primary = tax_details_primary
      @tax_rounding_mode = Amounts::Rounding.normalize_rounding_mode(
        tax_rounding_mode || rounding_mode || Amounts::Rounding::TAX_DEFAULT_MODE
      )
    end

    def call
      errors = []

      if to_i(@resolved[:subtotal]) + to_i(@resolved[:tax]) != to_i(@resolved[:total])
        errors << :total_mismatch
      end

      if item_total_mismatch?
        errors << :item_total_mismatch
      end

      if item_line_total_mismatch?
        errors << :item_total_mismatch
      end

      if to_i(@tax_total).positive? && to_i(@tax_total) != to_i(@resolved[:tax])
        errors << :tax_amount_mismatch
      end

      if tax_detail_incomplete?
        errors << :tax_detail_incomplete
      end

      if tax_detail_partial?
        errors << :tax_detail_partial
      end

      if tax_detail_mismatch?
        errors << :tax_detail_mismatch
      end

      if tax_detail_rate_mismatch?
        errors << :tax_detail_rate_mismatch
      end

      if item_tax_rate_group_uncertain?
        errors << :item_tax_rate_group_uncertain
      end

      if discount_data_incomplete?
        errors << :discount_data_incomplete
      end

      if zero_amount_item_incomplete?
        errors << :zero_amount_item_incomplete
      end

      if @context == :analysis
        if present?(@receipt[:total_amount]) && to_i(@receipt[:total_amount]) != to_i(@resolved[:total])
          errors << :ocr_total_mismatch
        end
      end

      # 税抜/税込混在の可能性検知
      if same_rate_mixed_item_amount_basis_uncertain? || mixed_tax_inclusion_suspected?
        errors << :price_tax_inclusion_uncertain
      end

      # 算出不能データ検知
      if insufficient_data?
        errors << :insufficient_data
      end

      errors.uniq
    end

    private

    def item_data_present?
      @item_count.positive?
    end

    def item_total_mismatch?
      return false unless item_data_present?
      return false if @tax_details_primary

      expected_total = @external_tax ? @resolved[:subtotal] : @resolved[:total]
      to_i(@item_total) != to_i(expected_total)
    end

    def item_line_total_mismatch?
      @items.any? { |item| item_line_total_conflicts_with_unit_total?(item) }
    end

    def item_line_total_conflicts_with_unit_total?(item)
      line_total = original_line_total_for(item)
      price = to_amount_decimal(fetch_value(item, :price))
      quantity = to_decimal(fetch_value(item, :quantity))
      quantity_unit = fetch_value(item, :quantity_unit)

      return false unless line_total.positive?
      return false unless price.positive?
      return false unless quantity.positive?
      return false unless countable_quantity_unit?(quantity_unit)

      unit_total = price * quantity
      return false if line_total == unit_total

      tax_rate = normalize_rate(fetch_value(item, :tax_rate))
      return true unless tax_rate.positive?

      !tax_adjusted_line_total_candidates(unit_total, tax_rate).include?(line_total)
    end

    def original_line_total_for(item)
      original_line_total = to_i(fetch_value(item, :original_line_total))
      return original_line_total if original_line_total.positive?

      line_total = to_i(fetch_value(item, :line_total))
      discount_amount = to_i(fetch_value(item, :discount_amount))
      line_total + discount_amount
    end

    def tax_adjusted_line_total_candidates(amount, tax_rate)
      %i[floor ceil round].flat_map do |rounding_mode|
        tax_from_net = Amounts::Rounding.apply_rounding(BigDecimal(amount.to_s) * tax_rate, rounding_mode)
        tax_from_gross = rounded_tax_from_gross(amount, tax_rate, rounding_mode)

        [
          amount + tax_from_net,
          amount - tax_from_gross
        ]
      end.uniq
    end

    def discount_data_incomplete?
      @items.any? do |item|
        discount_rate = normalize_rate(fetch_value(item, :discount_rate))
        discount_amount = to_i(fetch_value(item, :discount_amount))

        discount_rate.positive? && discount_amount <= 0
      end
    end

    def item_tax_total
      to_i(@computed[:item_tax_total])
    end

    def tax_detail_total
      to_i(@computed[:tax_detail_total])
    end

    def tax_detail_mismatch?
      return false if tax_detail_incomplete?
      return false if tax_detail_partial?
      return false if same_rate_mixed_item_amount_basis_uncertain?

      tax_detail_total.positive? &&
        item_tax_total.positive? &&
        tax_detail_total != item_tax_total &&
        !tax_details_match_rounding_candidate?
    end

    def tax_detail_rate_mismatch?
      return false if tax_detail_incomplete?
      return false if tax_detail_partial?
      return false if same_rate_mixed_item_amount_basis_uncertain?

      source_groups = tax_details_by_rate(comparable_source_tax_details)
      generated_groups = tax_details_by_rate(@generated_tax_details)

      return false if source_groups.blank? || generated_groups.blank?
      return false if @tax_details_primary
      return false if tax_details_match_rounding_candidate?(source_groups)

      source_groups.any? do |rate, source_amounts|
        generated_amounts = generated_groups[rate]
        next true if generated_amounts.blank?

        source_amounts[:amount] != generated_amounts[:amount] ||
          source_amounts[:net_amount] != generated_amounts[:net_amount]
      end
    end

    def item_tax_rate_group_uncertain?
      return false unless @context == :analysis
      return false if tax_detail_incomplete?
      return false if tax_detail_partial?

      source_rates = positive_tax_detail_rates
      item_rates = positive_item_tax_rates

      return false if source_rates.blank? || item_rates.blank?

      source_rates.map(&:to_s).sort != item_rates.map(&:to_s).sort
    end

    def tax_details_match_rounding_candidate?(source_groups = nil)
      source_groups ||= tax_details_by_rate(comparable_source_tax_details)
      return false if source_groups.blank? || @items.blank?

      %i[floor ceil round].any? do |rounding_mode|
        rounding_candidate_tax_details(rounding_mode) == source_groups
      end
    end

    def tax_detail_incomplete?
      comparable_source_tax_details.any? do |tax_detail|
        tax_detail_has_any_value?(tax_detail) && !tax_detail_complete?(tax_detail)
      end
    end

    def tax_detail_partial?
      return false if tax_detail_incomplete?

      receipt_tax_amount = to_i(fetch_value(@receipt, :tax_amount))
      comparable_tax_amount = receipt_tax_amount.positive? ? receipt_tax_amount : item_tax_total
      return false unless comparable_tax_amount.positive?
      return false unless tax_detail_total.positive?

      tax_detail_total < comparable_tax_amount
    end

    def tax_detail_has_any_value?(tax_detail)
      present?(fetch_value(tax_detail, :rate)) ||
        present?(fetch_value(tax_detail, :net_amount)) ||
        present?(fetch_value(tax_detail, :amount))
    end

    def tax_detail_complete?(tax_detail)
      normalize_rate(fetch_value(tax_detail, :rate)).positive? &&
        present?(fetch_value(tax_detail, :net_amount)) &&
        present?(fetch_value(tax_detail, :amount))
    end

    def rounding_candidate_tax_details(rounding_mode)
      gross_totals = @items.each_with_object({}) do |item, groups|
        rate = normalize_rate(fetch_value(item, :tax_rate))
        rate = normalize_rate(@resolved[:tax_rate]) if rate <= 0
        next if rate <= 0

        line_total = item_line_total(item)
        next if line_total <= 0

        groups[rate] ||= 0
        groups[rate] += line_total
      end

      gross_totals.each_with_object({}) do |(rate, gross_total), groups|
        tax_amount = rounded_tax_from_gross(gross_total, rate, rounding_mode)
        groups[rate] = {
          amount: tax_amount,
          net_amount: gross_total - tax_amount
        }
      end
    end

    def rounded_tax_from_gross(gross_total, tax_rate, rounding_mode)
      Amounts::Rounding.apply_rounding(BigDecimal(gross_total.to_s) * tax_rate / (BigDecimal("1") + tax_rate), rounding_mode)
    end

    def item_line_total(item)
      line_total = fetch_value(item, :line_total)
      return to_i(line_total) if line_total_present?(item)
      return 0 unless countable_quantity_unit?(fetch_value(item, :quantity_unit))

      price = to_amount_decimal(fetch_value(item, :price))
      quantity = to_decimal(fetch_value(item, :quantity))
      quantity = BigDecimal("1") if quantity <= 0

      round_amount(price * quantity)
    end

    def comparable_source_tax_details
      return @source_tax_details unless @external_tax

      details_with_net_amount = @source_tax_details.select do |tax_detail|
        to_i(fetch_value(tax_detail, :net_amount)).positive?
      end

      details_with_net_amount.presence || @source_tax_details
    end

    def tax_details_by_rate(tax_details)
      tax_details.each_with_object({}) do |tax_detail, groups|
        rate = normalize_rate(fetch_value(tax_detail, :rate))
        next if rate <= 0

        groups[rate] ||= { amount: 0, net_amount: 0 }
        groups[rate][:amount] += to_i(fetch_value(tax_detail, :amount))
        groups[rate][:net_amount] += to_i(fetch_value(tax_detail, :net_amount))
      end
    end

    def positive_tax_detail_rates
      comparable_source_tax_details.filter_map do |tax_detail|
        rate = normalize_rate(fetch_value(tax_detail, :rate))
        rate.positive? && tax_detail_complete?(tax_detail) ? rate : nil
      end.uniq
    end

    def positive_item_tax_rates
      @items.filter_map do |item|
        rate = normalize_rate(fetch_value(item, :tax_rate))
        rate.positive? ? rate : nil
      end.uniq
    end

    def same_rate_mixed_item_amount_basis_uncertain?
      return false unless @context == :analysis
      return false if tax_detail_incomplete? || tax_detail_partial?

      source_groups = tax_details_by_rate(comparable_source_tax_details)
      return false unless source_groups.one?

      rate, source_amounts = source_groups.first
      item_rates = @items.filter_map do |item|
        item_rate = normalize_rate(fetch_value(item, :tax_rate))
        item_rate.positive? ? item_rate : nil
      end.uniq
      return false unless item_rates == [ rate ]

      group_total = @items.sum do |item|
        normalize_rate(fetch_value(item, :tax_rate)) == rate ? item_line_total(item) : 0
      end
      printed_gross = source_amounts[:net_amount] + source_amounts[:amount]

      source_amounts[:net_amount] < group_total && group_total < printed_gross
    end

    def normalize_rate(value)
      return BigDecimal("0") if value.nil? || value == ""

      rate = BigDecimal(value.to_s)
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError
      BigDecimal("0")
    end

    def fetch_value(object, key)
      if object.respond_to?(:key?)
        return object[key] if object.key?(key)
        object[key.to_s] if object.key?(key.to_s)
      elsif object.respond_to?(:[])
        value = object[key]
        return value unless value.nil?

        string_value = object[key.to_s]
        string_value unless string_value.nil?
      elsif object.respond_to?(key)
        object.public_send(key)
      end
    end

    def mixed_tax_inclusion_suspected?
      return false unless @context == :analysis
      return true if tax_detail_partial? && mixed_tax_rate_items?

      ocr_total = to_i(@receipt[:total_amount])
      resolved_total = to_i(@resolved[:total])

      return false if ocr_total == 0 || resolved_total == 0

      # OCRとitems合計がズレている
      mismatch = ocr_total != resolved_total

      # tax mismatchが発生している（内訳もズレている）
      tax_mismatch = (to_i(@computed[:tax_detail_total]) != to_i(@computed[:item_tax_total]))

      # どちらかでも起きていれば「混在の可能性」とみなす
      mismatch && tax_mismatch
    end

    def mixed_tax_rate_items?
      has_taxable_item = false
      has_non_taxable_item = false

      @items.each do |item|
        rate = normalize_rate(fetch_value(item, :tax_rate))
        if rate.positive?
          has_taxable_item = true
        else
          has_non_taxable_item = true
        end
      end

      has_taxable_item && has_non_taxable_item
    end

    def insufficient_data?
      # 金額情報を持つ明細があればOK。0円明細も明示値なら有効な明細として扱う。
      has_items = to_i(@item_total).positive? || @items.any? { |item| item_amount_data_present?(item) }

      # tax_detailsやtotalなどの最低限データ
      has_tax_details = to_i(@computed[:tax_detail_total]).positive?
      has_total = to_i(@resolved[:total]).positive?

      # itemsが無く、かつ他の情報も弱い場合
      !has_items && !has_tax_details && !has_total
    end

    def zero_amount_item_incomplete?
      @items.any? do |item|
        explicit_zero_line_total?(item) &&
          !value_was_present?(item, :price) &&
          !value_was_present?(item, :quantity)
      end
    end

    def item_amount_data_present?(item)
      item_line_total(item).positive? || explicit_zero_amount_item?(item)
    end

    def explicit_zero_amount_item?(item)
      explicit_zero_line_total?(item) || explicit_zero_price_total?(item)
    end

    def explicit_zero_line_total?(item)
      line_total_present?(item) && to_i(fetch_value(item, :line_total)).zero?
    end

    def explicit_zero_price_total?(item)
      return false unless value_was_present?(item, :price)

      to_i(fetch_value(item, :price)).zero?
    end

    def line_total_present?(item)
      value_was_present?(item, :line_total)
    end

    def value_was_present?(item, key)
      flag = fetch_value(item, :"amount_#{key}_present")
      return flag if [ true, false ].include?(flag)

      present?(fetch_value(item, key))
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

    def to_i(value)
      Amounts::NumberParser.parse_amount(value)
    end

    def countable_quantity_unit?(unit)
      ReceiptItem::COUNTABLE_QUANTITY_UNITS.include?(unit.to_s.strip)
    end

    def present?(v)
      !v.nil? && v != ""
    end
  end
end
