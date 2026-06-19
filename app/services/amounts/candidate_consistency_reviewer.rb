# frozen_string_literal: true

module Amounts
  class CandidateConsistencyReviewer
    include Amounts::QuantityUnitResolver

    def initialize(receipt:, items:, tax_details:, context:)
      @receipt = receipt || {}
      @items = Array(items)
      @tax_details = Array(tax_details)
      @context = context.to_s.to_sym
    end

    def call(candidate)
      candidate.with_warnings(warnings_for(candidate))
    end

    private

    attr_reader :receipt, :items, :tax_details, :context

    def warnings_for(candidate)
      warnings = []
      warnings << :total_mismatch if total_mismatch?(candidate)
      warnings << :item_total_mismatch if item_total_mismatch?(candidate)
      warnings << :item_total_mismatch if item_line_total_mismatch?
      warnings << :tax_amount_mismatch if tax_amount_mismatch?(candidate)
      warnings << :tax_detail_incomplete if tax_detail_incomplete?
      warnings << :tax_detail_partial if tax_detail_partial?(candidate)
      warnings << :tax_detail_mismatch if tax_detail_mismatch?(candidate)
      warnings << :tax_detail_mismatch if impossible_tax_detail_present?
      warnings << :tax_detail_rate_mismatch if tax_detail_rate_mismatch?(candidate)
      warnings << :item_tax_rate_group_uncertain if item_tax_rate_group_uncertain?
      warnings << :zero_amount_item_incomplete if zero_amount_item_incomplete?
      warnings << :ocr_total_mismatch if ocr_total_mismatch?(candidate)
      warnings << :price_tax_inclusion_uncertain if price_tax_inclusion_uncertain?(candidate)
      warnings << :insufficient_data if insufficient_data?(candidate)

      warnings.uniq
    end

    def total_mismatch?(candidate)
      return false if candidate.basis == "receipt_input_preserved"
      return false if gross_tax_detail_amount_basis?(candidate)

      candidate.subtotal.to_i + candidate.tax.to_i != candidate.purchase_total.to_i
    end

    def item_total_mismatch?(candidate)
      return false unless item_data_present?
      return true if analysis_zero_item_positive_receipt_total?(candidate)
      return false if candidate.basis == "receipt_input_preserved"
      return false if candidate.basis.start_with?("printed_tax_details")
      return false if candidate.basis == "mixed_by_tax_rate_group"
      return false if discounted_original_line_total_tax_excluded_candidate?(candidate)

      expected_total = tax_excluded_total_candidate?(candidate) ? candidate.subtotal : candidate.purchase_total
      adjusted_item_total(candidate) != expected_total.to_i
    end

    def tax_amount_mismatch?(candidate)
      return false if stale_receipt_tax_amount_ignored?(candidate)
      return false unless receipt_tax_amount.positive?
      return false if price_tax_inclusion_uncertain?(candidate)

      receipt_tax_amount != candidate.tax.to_i
    end

    def tax_detail_incomplete?
      comparable_source_tax_details.any? do |tax_detail|
        tax_detail_has_any_value?(tax_detail) && !tax_detail_complete?(tax_detail)
      end
    end

    def tax_detail_partial?(candidate)
      return false if tax_detail_incomplete?

      comparable_tax_amount = receipt_tax_amount.positive? ? receipt_tax_amount : candidate.tax.to_i
      return false unless comparable_tax_amount.positive?
      return false unless source_tax_detail_total.positive?

      source_tax_detail_total < comparable_tax_amount
    end

    def tax_detail_mismatch?(candidate)
      return false if tax_detail_incomplete?
      return false if tax_detail_partial?(candidate)
      return false if price_tax_inclusion_uncertain?(candidate) && ambiguous_tax_inclusion_source?

      source_tax_detail_total.positive? &&
        candidate.tax.to_i.positive? &&
        source_tax_detail_total != candidate.tax.to_i &&
        !tax_details_match_rounding_candidate?(candidate)
    end

    def impossible_tax_detail_present?
      tax_details.any? do |tax_detail|
        rate = normalize_rate(fetch_value(tax_detail, :rate))
        net_amount = fetch_value(tax_detail, :net_amount)
        tax_amount = to_i(fetch_value(tax_detail, :amount))

        rate.positive? &&
          present?(net_amount) &&
          to_i(net_amount) <= 0 &&
          tax_amount.positive?
      end
    end

    def tax_detail_rate_mismatch?(candidate)
      return false if tax_detail_incomplete?
      return false if tax_detail_partial?(candidate)
      return false if price_tax_inclusion_uncertain?(candidate) && ambiguous_tax_inclusion_source?

      source_groups = tax_details_by_rate(comparable_source_tax_details)
      generated_groups = tax_details_by_rate(candidate.tax_details, normalize_basis: false)

      return false if source_groups.blank? || generated_groups.blank?
      return false if tax_details_match_rounding_candidate?(candidate, source_groups)

      source_groups.any? do |rate, source_amounts|
        generated_amounts = generated_groups[rate]
        next true if generated_amounts.blank?

        source_amounts[:amount] != generated_amounts[:amount] ||
          source_amounts[:net_amount] != generated_amounts[:net_amount]
      end
    end

    def item_tax_rate_group_uncertain?
      return false unless context == :analysis
      return false if tax_detail_incomplete?
      return false if tax_detail_partial_for_source?

      source_rates = positive_tax_detail_rates
      item_rates = positive_item_tax_rates

      return false if source_rates.blank? || item_rates.blank?

      source_rates.map(&:to_s).sort != item_rates.map(&:to_s).sort
    end

    def zero_amount_item_incomplete?
      items.any? do |item|
        explicit_zero_line_total?(item) &&
          !value_was_present?(item, :price) &&
          !value_was_present?(item, :quantity)
      end
    end

    def ocr_total_mismatch?(candidate)
      return false unless context == :analysis

      receipt_total = to_i(fetch_value(receipt, :total_amount))
      receipt_total.positive? && receipt_total != candidate.purchase_total.to_i
    end

    def price_tax_inclusion_uncertain?(candidate)
      candidate.warnings.include?(:price_tax_inclusion_uncertain) ||
        (tax_detail_partial?(candidate) && mixed_tax_rate_items?) ||
        same_rate_mixed_item_amount_basis_uncertain? ||
        printed_net_tax_details_with_recorded_item_subtotal?(candidate) ||
        mixed_tax_inclusion_suspected?(candidate)
    end

    def stale_receipt_tax_amount_ignored?(candidate)
      %i[manual edit_save].include?(context) &&
        item_derived_candidate?(candidate) &&
        candidate_item_total(candidate).positive?
    end

    def item_derived_candidate?(candidate)
      %w[
        items_as_tax_included
        items_as_tax_excluded
        mixed_by_tax_rate_group
      ].include?(candidate.basis.to_s)
    end

    def candidate_item_total(candidate)
      Array(candidate.computed_items).sum do |item|
        to_i(fetch_value(item, :line_total))
      end
    end

    def insufficient_data?(candidate)
      context == :analysis &&
        !item_data_present? &&
        source_tax_detail_total.zero? &&
        to_i(fetch_value(receipt, :total_amount)).zero? &&
        candidate.purchase_total.to_i.zero?
    end

    def analysis_zero_item_positive_receipt_total?(candidate)
      context == :analysis &&
        item_total.zero? &&
        explicit_zero_amount_item_present? &&
        to_i(fetch_value(receipt, :total_amount)).positive? &&
        candidate.purchase_total.to_i.zero?
    end

    def explicit_zero_amount_item_present?
      items.any? { |item| explicit_zero_amount_item?(item) }
    end

    def same_rate_mixed_item_amount_basis_uncertain?
      return false unless context == :analysis
      return false if tax_detail_incomplete? || tax_detail_partial_for_source?

      source_groups = tax_details_by_rate(comparable_source_tax_details)
      return false unless source_groups.one?

      rate, source_amounts = source_groups.first
      return false unless positive_item_tax_rates == [ rate ]

      group_total = items.sum do |item|
        normalize_rate(fetch_value(item, :tax_rate)) == rate ? item_line_total(item) : 0
      end
      printed_gross = source_amounts[:net_amount] + source_amounts[:amount]

      source_amounts[:net_amount] < group_total && group_total < printed_gross
    end

    def printed_net_tax_details_with_recorded_item_subtotal?(candidate)
      return false unless context == :analysis
      return false unless candidate.basis == "printed_tax_details_net"
      return false unless receipt_subtotal_tax_total_consistent?
      return false unless source_tax_details_match_receipt_net?
      return false unless item_total == receipt_subtotal_amount

      tax_detail_descriptions_suggest_gross?
    end

    def mixed_tax_inclusion_suspected?(candidate)
      return false unless context == :analysis
      return true if tax_detail_partial_for_source? && mixed_tax_rate_items?

      ocr_total = to_i(fetch_value(receipt, :total_amount))
      resolved_total = candidate.purchase_total.to_i

      return false if ocr_total.zero? || resolved_total.zero?

      ocr_total != resolved_total && source_tax_detail_total != candidate.tax.to_i
    end

    def tax_details_match_rounding_candidate?(candidate, source_groups = nil)
      source_groups ||= tax_details_by_rate(comparable_source_tax_details)
      return false if source_groups.blank? || items.blank?

      generated_groups = tax_details_by_rate(candidate.tax_details, normalize_basis: false)
      return true if generated_groups.present? && generated_groups == source_groups

      %i[floor ceil round].any? do |rounding_mode|
        rounding_candidate_tax_details(rounding_mode, candidate) == source_groups
      end
    end

    def rounding_candidate_tax_details(rounding_mode, candidate)
      gross_totals = items.each_with_object({}) do |item, groups|
        rate = normalize_rate(fetch_value(item, :tax_rate))
        rate = resolved_tax_rate(candidate) if rate <= 0
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

    def resolved_tax_rate(candidate)
      rates = candidate.tax_rate_groups.filter_map do |group|
        rate = normalize_rate(group[:rate])
        rate if rate.positive?
      end.uniq

      rates.one? ? rates.first : BigDecimal("0")
    end

    def comparable_source_tax_details
      details_with_net_amount = tax_details.select do |tax_detail|
        to_i(fetch_value(tax_detail, :net_amount)).positive?
      end

      details = details_with_net_amount.presence || tax_details
      final_tax_details(details).presence || details
    end

    def final_tax_details(details)
      detected = Amounts::TaxDetailBasisDetector.call(details)
      final_indexes = detected.filter_map do |detail|
        next if detail[:intermediate] || detail[:basis] == :summary

        detail[:index]
      end

      Array(details).values_at(*final_indexes).compact
    end

    def tax_details_by_rate(details, normalize_basis: true)
      comparable_details = normalize_basis ? normalized_tax_details_for_comparison(details) : raw_tax_details_for_comparison(details)
      comparable_details.each_with_object({}) do |tax_detail, groups|
        rate = tax_detail[:rate]
        next if rate <= 0

        groups[rate] ||= { amount: 0, net_amount: 0 }
        groups[rate][:amount] += tax_detail[:amount].to_i
        groups[rate][:net_amount] += tax_detail[:net_amount].to_i
      end
    end

    def raw_tax_details_for_comparison(details)
      Array(details).map do |tax_detail|
        {
          rate: normalize_rate(fetch_value(tax_detail, :rate)),
          amount: to_i(fetch_value(tax_detail, :amount)),
          net_amount: to_i(fetch_value(tax_detail, :net_amount))
        }
      end
    end

    def normalized_tax_details_for_comparison(details)
      Amounts::TaxDetailBasisDetector.call(details).map do |detail|
        {
          rate: detail[:rate],
          amount: detail[:amount],
          net_amount: detail[:target_net_amount]
        }
      end
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

    def tax_detail_partial_for_source?
      return false if tax_detail_incomplete?

      comparable_tax_amount = receipt_tax_amount.positive? ? receipt_tax_amount : source_tax_detail_total
      return false unless comparable_tax_amount.positive?
      return false unless source_tax_detail_total.positive?

      source_tax_detail_total < comparable_tax_amount
    end

    def receipt_tax_amount
      @receipt_tax_amount ||= to_i(fetch_value(receipt, :tax_amount))
    end

    def receipt_subtotal_amount
      @receipt_subtotal_amount ||= to_i(fetch_value(receipt, :subtotal_amount))
    end

    def receipt_total_amount
      @receipt_total_amount ||= to_i(fetch_value(receipt, :total_amount))
    end

    def receipt_subtotal_tax_total_consistent?
      receipt_subtotal_amount.positive? &&
        receipt_tax_amount.positive? &&
        receipt_total_amount.positive? &&
        receipt_subtotal_amount + receipt_tax_amount == receipt_total_amount
    end

    def source_tax_details_match_receipt_net?
      source_groups = tax_details_by_rate(comparable_source_tax_details)

      source_groups.present? &&
        source_groups.values.sum { |amounts| amounts[:net_amount] } == receipt_subtotal_amount &&
        source_tax_detail_total == receipt_tax_amount
    end

    def tax_detail_descriptions_suggest_gross?
      comparable_source_tax_details.any? do |tax_detail|
        fetch_value(tax_detail, :description).to_s.match?(profile.amount_tax_detail_gross_description_pattern)
      end
    end

    def source_tax_detail_total
      @source_tax_detail_total ||= comparable_source_tax_details.sum { |tax_detail| to_i(fetch_value(tax_detail, :amount)) }
    end

    def ambiguous_tax_inclusion_source?
      detected_tax_details.any? { |detail| detail[:basis] == :intermediate } ||
        detected_tax_details.map { |detail| detail[:basis] }.uniq.intersect?(%i[gross net]) &&
          detected_tax_details.map { |detail| detail[:rate] }.uniq.size > 1
    end

    def detected_tax_details
      @detected_tax_details ||= Amounts::TaxDetailBasisDetector.call(tax_details)
    end

    def generated_tax_total
      @generated_tax_total ||= tax_details_by_rate(comparable_source_tax_details).values.sum { |amounts| amounts[:amount] }
    end

    def positive_tax_detail_rates
      comparable_source_tax_details.filter_map do |tax_detail|
        rate = normalize_rate(fetch_value(tax_detail, :rate))
        rate.positive? && tax_detail_complete?(tax_detail) ? rate : nil
      end.uniq
    end

    def positive_item_tax_rates
      items.filter_map do |item|
        rate = normalize_rate(fetch_value(item, :tax_rate))
        rate.positive? ? rate : nil
      end.uniq
    end

    def mixed_tax_rate_items?
      positive = false
      zero = false

      items.each do |item|
        if normalize_rate(fetch_value(item, :tax_rate)).positive?
          positive = true
        else
          zero = true
        end
      end

      positive && zero
    end

    def item_line_total_mismatch?
      items.any? { |item| item_line_total_conflicts_with_unit_total?(item) }
    end

    def item_line_total_conflicts_with_unit_total?(item)
      line_total = original_line_total_for(item)
      price = BigDecimal(to_i(fetch_value(item, :price)).to_s)
      quantity = Amounts::NumberParser.parse_quantity(fetch_value(item, :quantity))

      return false unless line_total.positive?
      return false unless price.positive?
      return false unless quantity.positive?
      return false unless countable_quantity_unit_for_item?(item)

      unit_total = price * quantity
      return false if line_total == unit_total

      tax_rate = normalize_rate(fetch_value(item, :tax_rate))
      return true unless tax_rate.positive?

      !tax_adjusted_line_total_candidates(unit_total, tax_rate).include?(line_total)
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

    def rounded_tax_from_gross(gross_total, tax_rate, rounding_mode)
      Amounts::Rounding.apply_rounding(BigDecimal(gross_total.to_s) * tax_rate / (BigDecimal("1") + tax_rate), rounding_mode)
    end

    def item_data_present?
      item_total.positive? || items.any? { |item| item_amount_data_present?(item) }
    end

    def item_amount_data_present?(item)
      item_line_total(item).positive? || explicit_zero_amount_item?(item)
    end

    def explicit_zero_amount_item?(item)
      explicit_zero_line_total?(item) || explicit_zero_price_total?(item)
    end

    def explicit_zero_line_total?(item)
      value_was_present?(item, :line_total) && to_i(fetch_value(item, :line_total)).zero?
    end

    def explicit_zero_price_total?(item)
      value_was_present?(item, :price) && to_i(fetch_value(item, :price)).zero?
    end

    def adjusted_item_total(candidate)
      return candidate.subtotal.to_i if tax_excluded_total_candidate?(candidate)

      [ candidate_item_total(candidate) + candidate.purchase_adjustment_total.to_i, 0 ].max
    end

    def tax_excluded_total_candidate?(candidate)
      %w[external_tax_from_receipt items_as_tax_excluded printed_tax_details_net].include?(candidate.basis)
    end

    def discounted_original_line_total_tax_excluded_candidate?(candidate)
      candidate.basis == "items_as_tax_excluded" &&
        candidate_profile_value(candidate, :line_total_source).to_s == "discounted_original_line_total"
    end

    def gross_tax_detail_amount_basis?(candidate)
      candidate.basis == "printed_tax_details_gross" ||
        candidate_profile_value(candidate, :tax_detail_amount_basis).to_s == "gross"
    end

    def candidate_profile_value(candidate, key)
      profile = candidate.calculation_profile
      return nil unless profile.respond_to?(:key?)

      profile[key] || profile[key.to_s]
    end

    def item_total
      @item_total ||= items.sum { |item| item_line_total(item) }
    end

    def item_line_total(item)
      line_total = fetch_value(item, :line_total)
      return to_i(line_total) if value_was_present?(item, :line_total)
      return 0 unless countable_quantity_unit_for_item?(item)

      price = BigDecimal(to_i(fetch_value(item, :price)).to_s)
      quantity = Amounts::NumberParser.parse_quantity(fetch_value(item, :quantity))
      quantity = BigDecimal("1") if quantity <= 0

      BigDecimal(price.to_s).*(quantity).round(0).to_i
    end

    def original_line_total_for(item)
      original_line_total = to_i(fetch_value(item, :original_line_total))
      return original_line_total if original_line_total.positive?

      to_i(fetch_value(item, :line_total)) + to_i(fetch_value(item, :discount_amount))
    end

    def value_was_present?(item, key)
      flag = fetch_value(item, :"amount_#{key}_present")
      return flag if [ true, false ].include?(flag)

      present?(fetch_value(item, key))
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
      elsif object.respond_to?(key)
        object.public_send(key)
      end
    end

    def to_i(value)
      Amounts::NumberParser.parse_amount(value)
    end

    def profile
      ReceiptAnalysisProfiles.default
    end

    def present?(value)
      !value.nil? && value != ""
    end
  end
end
