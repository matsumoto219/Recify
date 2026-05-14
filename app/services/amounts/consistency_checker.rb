# frozen_string_literal: true

module Amounts
  class ConsistencyChecker
    def initialize(computed:, resolved:, item_total:, tax_total:, receipt:, context:, items: [], item_count: 0, external_tax: false, source_tax_details: [], generated_tax_details: [], tax_details_primary: false, rounding_mode: :floor)
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
      @rounding_mode = Amounts::Rounding.normalize_rounding_mode(rounding_mode)
    end

    def call
      errors = []

      if @resolved[:subtotal].to_i + @resolved[:tax].to_i != @resolved[:total].to_i
        errors << :total_mismatch
      end

      if item_total_mismatch?
        errors << :item_total_mismatch
      end

      if item_line_total_mismatch?
        errors << :item_total_mismatch
      end

      if @tax_total > 0 && @tax_total.to_i != @resolved[:tax].to_i
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

      if discount_data_incomplete?
        errors << :discount_data_incomplete
      end

      if zero_amount_item_incomplete?
        errors << :zero_amount_item_incomplete
      end

      if @context == :analysis
        if present?(@receipt[:total_amount]) && @receipt[:total_amount].to_i != @resolved[:total].to_i
          errors << :ocr_total_mismatch
        end
      end

      # 税抜/税込混在の可能性検知
      if mixed_tax_inclusion_suspected?
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
      @item_total.to_i != expected_total.to_i
    end

    def item_line_total_mismatch?
      @items.any? { |item| item_line_total_conflicts_with_unit_total?(item) }
    end

    def item_line_total_conflicts_with_unit_total?(item)
      line_total = original_line_total_for(item)
      price = fetch_value(item, :price).to_i
      quantity = fetch_value(item, :quantity).to_i

      return false unless line_total.positive?
      return false unless price.positive?
      return false unless quantity.positive?

      unit_total = price * quantity
      return false if line_total == unit_total

      tax_rate = normalize_rate(fetch_value(item, :tax_rate))
      return true unless tax_rate.positive?

      !tax_adjusted_line_total_candidates(unit_total, tax_rate).include?(line_total)
    end

    def original_line_total_for(item)
      original_line_total = fetch_value(item, :original_line_total).to_i
      return original_line_total if original_line_total.positive?

      line_total = fetch_value(item, :line_total).to_i
      discount_amount = fetch_value(item, :discount_amount).to_i
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
        discount_amount = fetch_value(item, :discount_amount).to_i

        discount_rate.positive? && discount_amount <= 0
      end
    end

    def item_tax_total
      @computed[:item_tax_total].to_i
    end

    def tax_detail_total
      @computed[:tax_detail_total].to_i
    end

    def tax_detail_mismatch?
      return false if tax_detail_incomplete?
      return false if tax_detail_partial?

      tax_detail_total.positive? &&
        item_tax_total.positive? &&
        tax_detail_total != item_tax_total &&
        !tax_details_match_rounding_candidate?
    end

    def tax_detail_rate_mismatch?
      return false if tax_detail_incomplete?
      return false if tax_detail_partial?

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

      receipt_tax_amount = fetch_value(@receipt, :tax_amount).to_i
      return false unless receipt_tax_amount.positive?
      return false unless tax_detail_total.positive?

      tax_detail_total < receipt_tax_amount
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
      return line_total.to_i if line_total_present?(item)

      price = fetch_value(item, :price).to_i
      quantity = fetch_value(item, :quantity).to_i
      quantity = 1 if quantity <= 0

      price * quantity
    end

    def comparable_source_tax_details
      return @source_tax_details unless @external_tax

      details_with_net_amount = @source_tax_details.select do |tax_detail|
        fetch_value(tax_detail, :net_amount).to_i.positive?
      end

      details_with_net_amount.presence || @source_tax_details
    end

    def tax_details_by_rate(tax_details)
      tax_details.each_with_object({}) do |tax_detail, groups|
        rate = normalize_rate(fetch_value(tax_detail, :rate))
        next if rate <= 0

        groups[rate] ||= { amount: 0, net_amount: 0 }
        groups[rate][:amount] += fetch_value(tax_detail, :amount).to_i
        groups[rate][:net_amount] += fetch_value(tax_detail, :net_amount).to_i
      end
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
        return object[key.to_s] if object.key?(key.to_s)
      elsif object.respond_to?(:[])
        value = object[key]
        return value unless value.nil?

        string_value = object[key.to_s]
        return string_value unless string_value.nil?
      elsif object.respond_to?(key)
        return object.public_send(key)
      end
    end

    def mixed_tax_inclusion_suspected?
      return false unless @context == :analysis

      ocr_total = @receipt[:total_amount].to_i
      resolved_total = @resolved[:total].to_i

      return false if ocr_total == 0 || resolved_total == 0

      # OCRとitems合計がズレている
      mismatch = ocr_total != resolved_total

      # tax mismatchが発生している（内訳もズレている）
      tax_mismatch = (@computed[:tax_detail_total].to_i != @computed[:item_tax_total].to_i)

      # どちらかでも起きていれば「混在の可能性」とみなす
      mismatch && tax_mismatch
    end

    def insufficient_data?
      # 金額情報を持つ明細があればOK。0円明細も明示値なら有効な明細として扱う。
      has_items = @item_total.to_i > 0 || @items.any? { |item| item_amount_data_present?(item) }

      # tax_detailsやtotalなどの最低限データ
      has_tax_details = @computed[:tax_detail_total].to_i > 0
      has_total = @resolved[:total].to_i > 0

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
      line_total_present?(item) && fetch_value(item, :line_total).to_i.zero?
    end

    def explicit_zero_price_total?(item)
      return false unless value_was_present?(item, :price)

      fetch_value(item, :price).to_i.zero?
    end

    def line_total_present?(item)
      value_was_present?(item, :line_total)
    end

    def value_was_present?(item, key)
      flag = fetch_value(item, :"amount_#{key}_present")
      return flag if [ true, false ].include?(flag)

      present?(fetch_value(item, key))
    end

    def present?(v)
      !v.nil? && v != ""
    end
  end
end
