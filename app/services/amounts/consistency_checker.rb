# frozen_string_literal: true

module Amounts
  class ConsistencyChecker
    def initialize(computed:, resolved:, item_total:, tax_total:, receipt:, context:, items: [], item_count: 0, external_tax: false, source_tax_details: [], generated_tax_details: [])
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
    end

    def call
      errors = []

      if @resolved[:subtotal].to_i + @resolved[:tax].to_i != @resolved[:total].to_i
        errors << :total_mismatch
      end

      if item_total_mismatch?
        errors << :item_total_mismatch
      end

      if @tax_total > 0 && @tax_total.to_i != @resolved[:tax].to_i
        errors << :tax_amount_mismatch
      end

      if tax_detail_total.positive? && item_tax_total.positive? && tax_detail_total != item_tax_total && !tax_details_match_rounding_candidate?
        errors << :tax_detail_mismatch
      end

      if tax_detail_rate_mismatch?
        errors << :tax_detail_rate_mismatch
      end

      if discount_data_incomplete?
        errors << :discount_data_incomplete
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

      expected_total = @external_tax ? @resolved[:subtotal] : @resolved[:total]
      @item_total.to_i != expected_total.to_i
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

    def tax_detail_rate_mismatch?
      source_groups = tax_details_by_rate(comparable_source_tax_details)
      generated_groups = tax_details_by_rate(@generated_tax_details)

      return false if source_groups.blank? || generated_groups.blank?
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
      value = BigDecimal(gross_total.to_s) * tax_rate / (BigDecimal("1") + tax_rate)

      case rounding_mode
      when :ceil
        value.ceil
      when :round
        value.round
      else
        value.floor
      end
    end

    def item_line_total(item)
      line_total = fetch_value(item, :line_total).to_i
      return line_total if line_total.positive?

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
      if object.respond_to?(:[])
        object[key] || object[key.to_s]
      elsif object.respond_to?(key)
        object.public_send(key)
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
      # itemsが1件でもあればOK
      has_items = @item_total.to_i > 0

      # tax_detailsやtotalなどの最低限データ
      has_tax_details = @computed[:tax_detail_total].to_i > 0
      has_total = @resolved[:total].to_i > 0

      # itemsが無く、かつ他の情報も弱い場合
      !has_items && !has_tax_details && !has_total
    end

    def present?(v)
      !v.nil? && v != ""
    end
  end
end
