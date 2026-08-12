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
      warnings << :item_total_mismatch if item_line_total_mismatch?(candidate)
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
      return false unless receipt_input_amount_relation_required?(candidate)
      return false if gross_tax_detail_amount_basis?(candidate)

      candidate.subtotal.to_i + candidate.tax.to_i != candidate.purchase_total.to_i
    end

    def receipt_input_amount_relation_required?(candidate)
      Amounts::ReceiptInputContract.amount_relation_required?(
        candidate: candidate,
        receipt: receipt,
        items: items,
        tax_details: tax_details
      )
    end

    def item_total_mismatch?(candidate)
      return false unless item_data_present?
      return true if analysis_zero_item_positive_receipt_total?(candidate)
      return false if candidate.basis == "receipt_input_preserved"
      return false if candidate.basis.start_with?("printed_tax_details")
      return false if candidate.basis == "mixed_by_tax_rate_group"
      return false if discounted_original_line_total_tax_excluded_candidate?(candidate)
      return false if item_derived_candidate?(candidate) && reference_quantity_price_item_present?

      expected_total = tax_excluded_total_candidate?(candidate) ? candidate.subtotal : candidate.purchase_total
      adjusted_item_total(candidate) != expected_total.to_i
    end

    def tax_amount_mismatch?(candidate)
      return false if preserved_incomplete_edit_input?(candidate)
      return false if stale_receipt_tax_amount_ignored?(candidate)
      return false if exact_mixed_candidate_resolved_by_tax_details?(candidate)
      return false unless receipt_tax_amount.positive?
      return false if price_tax_inclusion_uncertain?(candidate)

      receipt_tax_amount != candidate.tax.to_i
    end

    def preserved_incomplete_edit_input?(candidate)
      context == :edit_save &&
        candidate.basis == "receipt_input_preserved" &&
        !receipt_purchase_amount_data_present?
    end

    def tax_detail_incomplete?
      detected_tax_details.any? do |detail|
        tax_detail = tax_details[detail[:index]]
        next false unless tax_detail_has_any_value?(tax_detail)
        next false if detail[:basis] == :summary && tax_detail_evidence.final_detected_tax_details.present?

        !tax_detail_complete?(tax_detail)
      end
    end

    def tax_detail_partial?(candidate)
      return false if tax_detail_incomplete?
      return false if exact_mixed_candidate_resolved_by_tax_details?(candidate)

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
      return true if candidate.warnings.include?(:price_tax_inclusion_uncertain)
      return false if exact_mixed_candidate_resolved_by_tax_details?(candidate)

      (
        (tax_detail_partial?(candidate) && mixed_tax_rate_items?) ||
        same_rate_mixed_item_amount_basis_uncertain? ||
        printed_net_tax_details_with_recorded_item_subtotal?(candidate) ||
        mixed_tax_inclusion_suspected?(candidate)
      )
    end

    def exact_mixed_candidate_resolved_by_tax_details?(candidate)
      return false unless context == :analysis
      return false unless candidate.basis == "mixed_by_tax_rate_group"
      return false if candidate.hard_reject_reasons.present?
      return false unless mixed_candidate_target_evidence_complete?(candidate)
      return false unless receipt_total_amount.positive? && receipt_total_amount == candidate.purchase_total.to_i
      return false unless candidate.tax_details.present? && candidate.tax_rate_groups.present?

      candidate_tax_total = Array(candidate.tax_details).sum { |detail| to_i(fetch_value(detail, :amount)) }
      group_gross_total = Array(candidate.tax_rate_groups).sum { |group| to_i(fetch_value(group, :gross)) }

      candidate_tax_total == candidate.tax.to_i &&
        group_gross_total == candidate.purchase_total.to_i
    end

    def mixed_candidate_target_evidence_complete?(candidate)
      rates = candidate.tax_details.filter_map do |tax_detail|
        rate = normalize_rate(fetch_value(tax_detail, :rate))
        rate if rate.positive?
      end.uniq
      return false unless rates.many?

      rates.all? do |rate|
        comparable_source_tax_details.any? do |tax_detail|
          normalize_rate(fetch_value(tax_detail, :rate)) == rate &&
            fetch_value(tax_detail, :description).to_s.match?(profile.amount_tax_detail_gross_description_pattern)
        end
      end
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
      return analysis_insufficient_data?(candidate) if context == :analysis
      return false unless context == :edit_save

      !receipt_purchase_amount_data_present? &&
        !item_data_present? &&
        !tax_detail_amount_data_present? &&
        !positive_purchase_adjustment_total?(candidate)
    end

    def analysis_insufficient_data?(candidate)
      !item_data_present? &&
        source_tax_detail_total.zero? &&
        to_i(fetch_value(receipt, :total_amount)).zero? &&
        candidate.purchase_total.to_i.zero?
    end

    def receipt_purchase_amount_data_present?
      present?(fetch_value(receipt, :total_amount)) ||
        present?(fetch_value(receipt, :subtotal_amount)) && present?(fetch_value(receipt, :tax_amount))
    end

    def tax_detail_amount_data_present?
      tax_detail_evidence.purchase_amount_evidence_present?
    end

    def tax_detail_evidence
      @tax_detail_evidence ||= Amounts::TaxDetailEvidence.new(tax_details)
    end

    def positive_purchase_adjustment_total?(candidate)
      candidate.purchase_adjustment_total.to_i.positive?
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

    def item_line_total_mismatch?(candidate)
      items.each_with_index.any? do |item, index|
        case pricing_source_kind_for(item)
        when "explicit_line_total"
          explicit_reference_diagnostic_mismatch?(item, candidate, index)
        when "reference_quantity_price"
          false
        when nil, "count_unit_price"
          item_line_total_conflicts_with_unit_total?(item)
        else
          false
        end
      end
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

    def explicit_reference_diagnostic_mismatch?(item, candidate, index)
      extension = explicit_reference_diagnostic_extension(item, candidate, index)
      return false unless extension

      printed_total = explicit_reference_comparison_total(item)
      return false if printed_total.nil?

      rounding_candidates = [
        extension.exact_amount.floor,
        extension.projected_amount,
        extension.exact_amount.ceil
      ].uniq

      !rounding_candidates.include?(printed_total)
    end

    def explicit_reference_diagnostic_extension(item, candidate, index)
      return nil unless value_was_present?(item, :line_total)

      tax_inclusion = fetch_value(item, :reference_price_tax_inclusion).to_s
      return nil unless candidate_item_reference_tax_inclusion(candidate, index, item) == tax_inclusion

      reference_extension_result(item)
    end

    def explicit_reference_comparison_total(item)
      line_total = to_i(fetch_value(item, :line_total))
      discount_amount_present = value_was_present?(item, :discount_amount)
      return line_total unless discount_amount_present || present?(fetch_value(item, :discount_rate))
      return nil unless discount_amount_present
      return nil unless present?(fetch_value(item, :original_line_total))

      original_line_total = to_i(fetch_value(item, :original_line_total))
      discount_amount = to_i(fetch_value(item, :discount_amount))
      return nil if original_line_total.negative? || discount_amount.negative?
      return nil unless [ original_line_total - discount_amount, 0 ].max == line_total

      original_line_total
    end

    def candidate_item_reference_tax_inclusion(candidate, index, item)
      source_tax_inclusion = fetch_value(item, :reference_price_tax_inclusion).to_s
      return source_tax_inclusion if explicit_zero_tax_rate?(fetch_value(item, :tax_rate))
      return "gross" if pricing_source_kind_for(item) == "explicit_line_total"

      assignment_basis = candidate_item_amount_basis_assignment(candidate, index)
      return reference_tax_inclusion_for_item_basis(assignment_basis) if assignment_basis

      profile_basis = candidate_profile_value(candidate, :item_amount_basis)&.to_sym
      case profile_basis
      when :line_total_as_recorded
        return "gross"
      when :line_total_as_net
        return "net"
      end

      case candidate.basis
      when "items_as_tax_included"
        "gross"
      when "items_as_tax_excluded"
        "net"
      end
    end

    def explicit_zero_tax_rate?(value)
      return false unless present?(value)

      BigDecimal(value.to_s.delete("%")).zero?
    rescue ArgumentError
      false
    end

    def candidate_item_amount_basis_assignment(candidate, index)
      assignments = Array(candidate_profile_value(candidate, :item_amount_basis_assignments))
      matching = assignments.select do |assignment|
        next false unless fetch_value(assignment, :assignment_scope).to_s == "item"

        Array(fetch_value(assignment, :item_indices)).map(&:to_i).include?(index)
      end
      return nil unless matching.one?

      fetch_value(matching.first, :basis)&.to_sym
    end

    def reference_tax_inclusion_for_item_basis(basis)
      case basis
      when :tax_included
        "gross"
      when :tax_excluded
        "net"
      end
    end

    def reference_quantity_price_item_present?
      items.any? { |item| pricing_source_kind_for(item) == "reference_quantity_price" }
    end

    def reference_extension_result(item)
      return nil unless valid_reference_price_amount_for_diagnostic?(item)
      return nil unless valid_reference_quantity_for_diagnostic?(item)
      return nil unless valid_purchased_quantity_for_diagnostic?(item)
      return nil unless canonical_reference_unit_code?(fetch_value(item, :quantity_unit_code))
      return nil unless canonical_reference_unit_code?(fetch_value(item, :reference_quantity_unit_code))
      return nil unless fetch_value(item, :quantity_unit_raw).nil?
      return nil unless fetch_value(item, :reference_quantity_unit_raw).nil?

      Amounts::ReferenceItemExtension.call(
        reference_price_amount: fetch_value(item, :reference_price_amount),
        reference_quantity: fetch_value(item, :reference_quantity),
        reference_unit_code: fetch_value(item, :reference_quantity_unit_code),
        purchased_quantity: fetch_value(item, :quantity),
        purchased_unit_code: fetch_value(item, :quantity_unit_code),
        reference_price_tax_inclusion: fetch_value(item, :reference_price_tax_inclusion)
      )
    rescue Amounts::ReferenceItemExtension::InvalidSourceError,
      Amounts::ItemQuantitySemantics::InvalidFormulaSourceError,
      ReceiptQuantityUnit::ConversionError
      nil
    end

    def valid_reference_price_amount_for_diagnostic?(item)
      exact_bounded_decimal_for_diagnostic?(
        fetch_value(item, :reference_price_amount),
        minimum: 0,
        maximum: ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX.to_r,
        maximum_scale: ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX_SCALE,
        minimum_inclusive: true
      )
    end

    def valid_reference_quantity_for_diagnostic?(item)
      exact_bounded_decimal_for_diagnostic?(
        fetch_value(item, :reference_quantity),
        minimum: 0,
        maximum: ReceiptItem::REFERENCE_QUANTITY_MAX.to_r,
        maximum_scale: ReceiptItem::REFERENCE_QUANTITY_MAX_SCALE,
        minimum_inclusive: false
      )
    end

    def valid_purchased_quantity_for_diagnostic?(item)
      exact_bounded_decimal_for_diagnostic?(
        fetch_value(item, :quantity),
        minimum: 0,
        maximum: ReceiptItem::REFERENCE_QUANTITY_MAX.to_r,
        maximum_scale: ReceiptItem::REFERENCE_QUANTITY_MAX_SCALE,
        minimum_inclusive: false
      )
    end

    def exact_bounded_decimal_for_diagnostic?(value, minimum:, maximum:, maximum_scale:, minimum_inclusive:)
      exact = exact_decimal_for_diagnostic(value)
      return false unless exact
      return false if minimum_inclusive ? exact < minimum : exact <= minimum
      return false if exact > maximum

      decimal_scale_for_diagnostic(exact)&.<=(maximum_scale)
    end

    def exact_decimal_for_diagnostic(value)
      case value
      when Integer, Rational
        value.to_r
      when BigDecimal
        value.to_r if value.finite?
      when String
        Rational(value) if value.match?(/\A[+-]?\d+(?:\.\d+)?\z/)
      end
    rescue ArgumentError, TypeError, FloatDomainError, ZeroDivisionError
      nil
    end

    def decimal_scale_for_diagnostic(value)
      denominator = value.denominator
      powers_of_two = factor_count_for_diagnostic(denominator, 2)
      denominator /= 2**powers_of_two
      powers_of_five = factor_count_for_diagnostic(denominator, 5)
      denominator /= 5**powers_of_five

      [ powers_of_two, powers_of_five ].max if denominator == 1
    end

    def factor_count_for_diagnostic(value, factor)
      count = 0
      while (value % factor).zero?
        count += 1
        value /= factor
      end
      count
    end

    def canonical_reference_unit_code?(code)
      code.is_a?(String) && ReceiptQuantityUnit.unit_for(code)&.code == code
    end

    def pricing_source_kind_for(item)
      fetch_value(item, :pricing_source_kind)&.to_s.presence
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
      item_line_total(item).positive? ||
        explicit_zero_amount_item?(item) ||
        reference_formula_item_data_present?(item)
    end

    def reference_formula_item_data_present?(item)
      pricing_source_kind_for(item) == "reference_quantity_price" && !reference_extension_result(item).nil?
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
      return true if flag == true
      return persisted_item_amount_present?(item, key) if flag == false

      present?(fetch_value(item, key))
    end

    def persisted_item_amount_present?(item, key)
      return false unless fetch_value(item, :amount_persisted_item) == true
      return false unless %i[price line_total].include?(key)
      return false if key == :line_total && fetch_value(item, :amount_line_total_changed) == true

      value = if key == :line_total
        fetch_value(item, :amount_persisted_line_total)
      else
        fetch_value(item, key)
      end
      present?(value)
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
