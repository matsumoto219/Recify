# frozen_string_literal: true

module Amounts
  class CandidateGenerator
    ROUNDING_MODES = %i[floor round ceil].freeze
    SAME_RATE_MIXED_MAX_ITEMS = 20
    SAME_RATE_MIXED_MAX_STATES = 50_000

    def initialize(receipt:, items:, tax_details:, adjustments:, payments:, context:, tax_rounding_modes:, discount_rounding_modes: nil, tax_excluded_price_conversion_enabled: true)
      @receipt = receipt
      @source_items = Array(items)
      @items = @source_items
      @tax_details = Array(tax_details)
      @adjustments = Array(adjustments)
      @payments = Array(payments)
      @context = context
      @tax_rounding_modes = Array(tax_rounding_modes).presence || ROUNDING_MODES
      @discount_rounding_modes = normalize_rounding_modes(discount_rounding_modes || [ Amounts::Rounding::DISCOUNT_DEFAULT_MODE ])
      @tax_excluded_price_conversion_enabled = tax_excluded_price_conversion_enabled != false
    end

    def call
      discount_rounding_modes.flat_map { |rounding_mode| candidates_for_discount_rounding_mode(rounding_mode) }
    end

    private

    attr_reader :receipt, :source_items, :items, :tax_details, :adjustments, :payments, :context, :tax_rounding_modes, :discount_rounding_modes, :discount_rounding_mode, :tax_excluded_price_conversion_enabled

    def candidates_for_discount_rounding_mode(rounding_mode)
      @discount_rounding_mode = rounding_mode
      @items = normalize_items(rounding_mode)
      reset_item_dependent_cache

      [
        receipt_input_candidate,
        incomplete_tax_details_receipt_tax_candidate,
        item_candidates,
        printed_tax_detail_candidates,
        mixed_candidates
      ].flatten.compact
    end

    def normalize_items(rounding_mode)
      Amounts::ItemTotalAggregator.new(
        items: source_items,
        context: context,
        discount_rounding_mode: rounding_mode
      ).call[:items]
    end

    def reset_item_dependent_cache
      @item_total = nil
      @fallback_tax_rate = nil
      @incomplete_source_tax_details = nil
    end

    def receipt_input_candidate
      return nil unless receipt_input_candidate_needed?

      resolved = receipt_input_resolved_values
      purchase_total = to_i(resolved[:total])
      payment = payment_reconciliation(purchase_total, payment_adjustment_total)
      item_delta = item_total_delta(purchase_total)

      Amounts::Candidate.new(
        candidate_id: receipt_input_candidate_id,
        basis: "receipt_input_preserved",
        subtotal: to_i(resolved[:subtotal]),
        tax: to_i(resolved[:tax]),
        purchase_total: purchase_total,
        final_payment_total: payment[:final_payment_total],
        purchase_adjustment_total: purchase_adjustment_total,
        payment_adjustment_total: payment_adjustment_total,
        payment_amount_sum: payment[:payment_amount_sum],
        tax_details: receipt_input_tax_details,
        tax_rate_groups: receipt_input_tax_rate_groups(resolved),
        rounding_mode: :floor,
        rounding_scope: :per_receipt,
        warnings: (receipt_input_warnings(item_delta) + payment_warnings(payment)).uniq,
        evidence: payment[:evidence] + [ {
          source: "receipt_input",
          formula: "receipt_input_preserved",
          purchase_total: purchase_total,
          item_total: item_data_present? ? item_total : nil,
          item_delta: item_delta
        }.compact ],
        computed_items: items,
        calculation_profile: calculation_profile(
          receipt_input_resolved: resolved,
          receipt_input_tax_rate_present: value_present?(receipt[:tax_rate])
        ),
        source: :amount_engine
      )
    end

    def receipt_input_candidate_needed?
      case context.to_s.to_sym
      when :manual
        receipt_input_present? || (!item_data_present? && !tax_detail_data_present?)
      when :edit_save
        receipt_input_present?
      when :analysis
        receipt_input_present? &&
          (
            (!item_data_present? && !tax_detail_data_present?) ||
              analysis_receipt_input_conflict_candidate_needed?
          )
      else
        false
      end
    end

    def receipt_input_candidate_id
      case context.to_s.to_sym
      when :edit_save
        "edit_saved_input"
      when :manual
        "manual_receipt_input"
      else
        "analysis_receipt_input"
      end
    end

    def receipt_input_present?
      %i[total_amount subtotal_amount tax_amount tax_rate].any? { |key| value_present?(receipt[key]) }
    end

    def tax_detail_data_present?
      tax_details.any? do |tax_detail|
        %i[rate net_amount amount].any? { |key| value_present?(fetch_value(tax_detail, key)) }
      end
    end

    def receipt_input_resolved_values
      return empty_receipt_input_values unless receipt_input_present?

      total = amount_or_nil(receipt[:total_amount])
      subtotal = amount_or_nil(receipt[:subtotal_amount])
      tax = amount_or_nil(receipt[:tax_amount])
      if analysis_receipt_input_conflict_candidate_needed? &&
          total&.positive? &&
          tax&.positive? &&
          (subtotal.nil? || subtotal + tax != total)
        subtotal = fallback_subtotal(total, tax)
      end

      {
        subtotal: subtotal.nil? ? fallback_subtotal(total, tax) : subtotal,
        tax: tax.nil? ? fallback_tax(total, subtotal) : tax,
        total: total.nil? ? fallback_total(subtotal, tax) : total,
        tax_rate: receipt_input_tax_rate(subtotal, tax, total)
      }
    end

    def empty_receipt_input_values
      {
        subtotal: nil,
        tax: nil,
        total: nil,
        tax_rate: nil
      }
    end

    def fallback_subtotal(total, tax)
      return total - tax if total && tax

      0
    end

    def fallback_tax(total, subtotal)
      return total - subtotal if total && subtotal

      0
    end

    def fallback_total(subtotal, tax)
      return subtotal + tax if subtotal && tax

      0
    end

    def receipt_input_tax_rate(subtotal, tax, total)
      return normalize_rate(receipt[:tax_rate]) if value_present?(receipt[:tax_rate])

      resolved_subtotal = subtotal || (total && tax ? fallback_subtotal(total, tax) : nil)
      resolved_tax = tax

      return nil if resolved_tax.nil? || resolved_subtotal.nil?
      return BigDecimal("0") if resolved_tax.zero?
      return nil unless receipt_input_tax_rate_inference_allowed?
      return nil unless resolved_subtotal.to_i.positive?

      BigDecimal(resolved_tax.to_s) / BigDecimal(resolved_subtotal.to_s)
    end

    def receipt_input_tax_rate_inference_allowed?
      positive_item_rates = items.filter_map do |item|
        rate = normalize_rate(indifferent_hash(item)[:tax_rate])
        rate if rate.positive?
      end.uniq
      positive_detail_rates = tax_details.filter_map do |tax_detail|
        rate = normalize_rate(fetch_value(tax_detail, :rate))
        rate if rate.positive?
      end.uniq

      positive_item_rates.size <= 1 && positive_detail_rates.size <= 1
    end

    def receipt_input_tax_rate_groups(resolved)
      rate = resolved[:tax_rate]
      return [] unless rate.respond_to?(:positive?)

      [
        {
          rate: rate,
          gross: to_i(resolved[:total]),
          net: to_i(resolved[:subtotal]),
          tax: to_i(resolved[:tax])
        }
      ]
    end

    def receipt_input_tax_details
      return [] unless analysis_receipt_input_conflict_candidate_needed?

      tax_details.map do |tax_detail|
        {
          description: fetch_value(tax_detail, :description),
          rate: normalize_rate(fetch_value(tax_detail, :rate)),
          net_amount: amount_or_nil(fetch_value(tax_detail, :net_amount)),
          amount: amount_or_nil(fetch_value(tax_detail, :amount))
        }.compact
      end
    end

    def receipt_input_warnings(item_delta)
      warnings = []
      warnings << :item_total_mismatch if item_delta.to_i > receipt_input_item_delta_threshold
      warnings << :tax_detail_mismatch if impossible_tax_detail_present?
      warnings
    end

    def analysis_receipt_input_conflict_candidate_needed?
      context.to_s.to_sym == :analysis &&
        receipt_payment_total_matches? &&
        impossible_tax_detail_present?
    end

    def receipt_payment_total_matches?
      total = amount_or_nil(receipt[:total_amount])
      return false unless total&.positive?

      payment_sum = payments.sum { |payment| amount_or_nil(fetch_value(payment, :amount)).to_i }
      payment_sum == total
    end

    def impossible_tax_detail_present?
      tax_details.any? do |tax_detail|
        rate = normalize_rate(fetch_value(tax_detail, :rate))
        net_amount = fetch_value(tax_detail, :net_amount)
        tax_amount = amount_or_nil(fetch_value(tax_detail, :amount))

        rate.positive? &&
          value_present?(net_amount) &&
          amount_or_nil(net_amount).to_i <= 0 &&
          tax_amount&.positive?
      end
    end

    def item_total_delta(purchase_total)
      return 0 unless item_data_present?

      ([ item_total + purchase_adjustment_total, 0 ].max - purchase_total.to_i).abs
    end

    def receipt_input_item_delta_threshold
      return 0 unless item_data_present?

      [ 100, (BigDecimal(item_total.to_s) * BigDecimal("0.20")).to_i ].max
    end

    def item_candidates
      tax_rounding_modes.flat_map do |rounding_mode|
        Amounts::RoundingScope::SCOPES.flat_map do |rounding_scope|
          [
            items_as_tax_included_candidate(rounding_mode, rounding_scope),
            items_as_tax_excluded_candidate(rounding_mode, rounding_scope),
            discounted_original_line_total_tax_excluded_candidate(rounding_mode, rounding_scope)
          ].compact
        end
      end
    end

    def incomplete_tax_details_receipt_tax_candidate
      return nil unless context.to_s.to_sym == :analysis

      total = amount_or_nil(receipt[:total_amount])
      tax = amount_or_nil(receipt[:tax_amount])
      return nil unless total&.positive? && tax&.positive? && total >= tax
      return nil unless adjusted_item_total == total
      return nil unless item_tax_rates_missing?
      return nil unless incomplete_tax_detail_amounts_present?

      payment = payment_reconciliation(total, payment_adjustment_total)

      Amounts::Candidate.new(
        candidate_id: "incomplete_tax_details_receipt_tax/floor",
        basis: "incomplete_tax_details_receipt_tax",
        subtotal: total - tax,
        tax: tax,
        purchase_total: total,
        final_payment_total: payment[:final_payment_total],
        purchase_adjustment_total: purchase_adjustment_total,
        payment_adjustment_total: payment_adjustment_total,
        payment_amount_sum: payment[:payment_amount_sum],
        tax_details: [],
        tax_rate_groups: [],
        rounding_mode: :floor,
        rounding_scope: :per_receipt,
        warnings: (adjustment_warnings + payment_warnings(payment) + [ :tax_detail_incomplete ]).uniq,
        evidence: incomplete_tax_detail_evidence + adjustment_evidence + payment[:evidence] + [ {
          source: "receipt_input",
          formula: "incomplete_tax_details_receipt_tax",
          purchase_total: total,
          tax: tax,
          subtotal: total - tax,
          item_total: item_total
        } ],
        computed_items: items,
        calculation_profile: calculation_profile(
          receipt_tax_basis: :total_includes_tax,
          item_amount_basis: :line_total_as_recorded,
          tax_detail_amount_basis: :unknown,
          receipt_tax_amount_preserved: true
        ),
        source: :amount_engine
      )
    end

    def items_as_tax_included_candidate(rounding_mode, rounding_scope)
      build_item_candidate(
        candidate_id: "items_as_tax_included/#{rounding_mode}/#{rounding_scope}",
        basis: "items_as_tax_included",
        item_basis: :tax_included,
        rounding_mode: rounding_mode,
        rounding_scope: rounding_scope
      )
    end

    def items_as_tax_excluded_candidate(rounding_mode, rounding_scope)
      return nil unless tax_excluded_price_conversion_enabled?

      build_item_candidate(
        candidate_id: "items_as_tax_excluded/#{rounding_mode}/#{rounding_scope}",
        basis: "items_as_tax_excluded",
        item_basis: :tax_excluded,
        rounding_mode: rounding_mode,
        rounding_scope: rounding_scope
      )
    end

    def discounted_original_line_total_tax_excluded_candidate(rounding_mode, rounding_scope)
      return nil unless tax_excluded_price_conversion_enabled?
      return nil unless discounted_original_line_total_tax_excluded_candidate_needed?

      build_item_candidate(
        candidate_id: "items_as_tax_excluded/#{rounding_mode}/#{rounding_scope}/original_line_total",
        basis: "items_as_tax_excluded",
        item_basis: :tax_excluded,
        rounding_mode: rounding_mode,
        rounding_scope: rounding_scope,
        line_total_source: :discounted_original_line_total
      )
    end

    def build_item_candidate(candidate_id:, basis:, item_basis:, rounding_mode:, rounding_scope:, line_total_source: :line_total)
      groups = empty_groups
      computed_items = []

      items.each_with_index do |item, index|
        line_total = item_basis_line_total(item, item_basis: item_basis, line_total_source: line_total_source)
        rate = item_tax_rate(item)
        group = groups[rate]

        amounts = item_basis_amounts(line_total, rate, item_basis, rounding_mode)
        group[:item_amounts] << amounts
        computed_items[index] = item_with_line_total(
          item,
          amounts[:gross_amount],
          normalize_price: item_basis == :tax_excluded
        )
      end

      apply_purchase_adjustments_to_groups!(groups, item_basis: item_basis, rounding_mode: rounding_mode)
      tax_rate_groups = build_tax_rate_groups(groups, rounding_mode, rounding_scope, item_basis: item_basis)
      purchase_total = tax_rate_groups.sum { |group| group[:gross] }
      tax = tax_rate_groups.sum { |group| group[:tax] }
      payment = payment_reconciliation(purchase_total, payment_adjustment_total)
      warnings = adjustment_warnings + payment_warnings(payment)

      Amounts::Candidate.new(
        candidate_id: candidate_id,
        basis: basis,
        subtotal: purchase_total - tax,
        tax: tax,
        purchase_total: purchase_total,
        final_payment_total: payment[:final_payment_total],
        purchase_adjustment_total: purchase_adjustment_total,
        payment_adjustment_total: payment_adjustment_total,
        payment_amount_sum: payment[:payment_amount_sum],
        tax_details: tax_details_from_groups(tax_rate_groups),
        tax_rate_groups: tax_rate_groups,
        rounding_mode: rounding_mode,
        rounding_scope: rounding_scope,
        warnings: warnings.uniq,
        evidence: adjustment_evidence + payment[:evidence] + [
          {
            source: "receipt_items",
            formula: basis,
            purchase_total: purchase_total,
            line_total_source: item_candidate_line_total_source(line_total_source)
          }.compact
        ],
        computed_items: computed_items,
        calculation_profile: item_candidate_calculation_profile(line_total_source),
        source: :amount_engine
      )
    end

    def printed_tax_detail_candidates
      return [] if detected_tax_details.blank?

      tax_rounding_modes.flat_map do |rounding_mode|
        [
          printed_tax_details_candidate(
            candidate_id: "printed_tax_details_gross/#{rounding_mode}",
            basis: "printed_tax_details_gross",
            amount_basis: :gross,
            rounding_mode: rounding_mode
          ),
          printed_tax_details_candidate(
            candidate_id: "printed_tax_details_net/#{rounding_mode}",
            basis: "printed_tax_details_net",
            amount_basis: :net,
            rounding_mode: rounding_mode
          ),
          printed_tax_details_candidate(
            candidate_id: "external_tax_from_receipt/#{rounding_mode}",
            basis: "external_tax_from_receipt",
            amount_basis: :detected,
            rounding_mode: rounding_mode
          ),
          raw_printed_tax_details_candidate(rounding_mode)
        ]
      end
    end

    def printed_tax_details_candidate(candidate_id:, basis:, amount_basis:, rounding_mode:)
      groups = final_detected_tax_details.each_with_object({}) do |detail, hash|
        rate = detail[:rate]
        next unless rate.positive?

        amounts = tax_detail_amounts_for(detail, amount_basis)
        hash[rate] ||= { rate: rate, gross: 0, net: 0, tax: 0 }
        hash[rate][:gross] += amounts[:gross]
        hash[rate][:net] += amounts[:net]
        hash[rate][:tax] += amounts[:tax]
      end

      non_taxable_item_total = non_taxable_item_total_for_printed_tax_details(groups.values)
      if non_taxable_item_total.positive?
        groups[BigDecimal("0")] ||= { rate: BigDecimal("0"), gross: 0, net: 0, tax: 0 }
        groups[BigDecimal("0")][:gross] += non_taxable_item_total
        groups[BigDecimal("0")][:net] += non_taxable_item_total
      end

      gross_basis = gross_tax_detail_candidate?(amount_basis)
      applied_purchase_adjustment_total = tax_detail_purchase_adjustment_total(groups.values, gross_basis: gross_basis)
      purchase_total = groups.values.sum { |group| group[:gross] } + applied_purchase_adjustment_total
      tax = groups.values.sum { |group| group[:tax] }
      payment = payment_reconciliation(purchase_total, payment_adjustment_total)
      tax_detail_amount_basis = gross_basis ? :gross : :net

      Amounts::Candidate.new(
        candidate_id: candidate_id,
        basis: basis,
        subtotal: purchase_total - tax,
        tax: tax,
        purchase_total: purchase_total,
        final_payment_total: payment[:final_payment_total],
        purchase_adjustment_total: purchase_adjustment_total,
        payment_adjustment_total: payment_adjustment_total,
        payment_amount_sum: payment[:payment_amount_sum],
        tax_details: tax_details_from_printed_groups(groups.values, gross_basis: gross_basis),
        tax_rate_groups: groups.values,
        rounding_mode: rounding_mode,
        rounding_scope: :per_tax_rate_group,
        warnings: (adjustment_warnings + payment_warnings(payment)).uniq,
        evidence: final_detected_tax_details.map { |detail| detail[:evidence] } + adjustment_evidence + payment[:evidence] + [
          {
            source: "amount_engine",
            formula: basis,
            tax_detail_amount_basis: tax_detail_amount_basis,
            applied_purchase_adjustment_total: applied_purchase_adjustment_total
          }
        ],
        computed_items: items,
        calculation_profile: calculation_profile(
          receipt_tax_basis: gross_basis ? :total_includes_tax : :tax_added_to_subtotal,
          item_amount_basis: printed_tax_detail_item_amount_basis(basis, purchase_total),
          tax_detail_amount_basis: tax_detail_amount_basis
        ),
        source: :amount_engine
      )
    end

    def raw_printed_tax_details_candidate(rounding_mode)
      groups = detected_tax_details.each_with_object({}) do |detail, hash|
        rate = detail[:rate]
        next unless rate.positive?
        next unless detail[:net_amount].to_i.positive? && detail[:amount].to_i.positive?

        hash[rate] ||= { rate: rate, gross: 0, net: 0, tax: 0 }
        hash[rate][:net] += detail[:net_amount].to_i
        hash[rate][:tax] += detail[:amount].to_i
        hash[rate][:gross] += detail[:net_amount].to_i + detail[:amount].to_i
      end

      purchase_total = groups.values.sum { |group| group[:gross] }
      payment = payment_reconciliation(purchase_total, payment_adjustment_total)

      Amounts::Candidate.new(
        candidate_id: "printed_tax_details_raw_sum/#{rounding_mode}",
        basis: "printed_tax_details_raw_sum",
        subtotal: purchase_total - groups.values.sum { |group| group[:tax] },
        tax: groups.values.sum { |group| group[:tax] },
        purchase_total: purchase_total,
        final_payment_total: payment[:final_payment_total],
        purchase_adjustment_total: 0,
        payment_adjustment_total: payment_adjustment_total,
        payment_amount_sum: payment[:payment_amount_sum],
        tax_details: tax_details_from_groups(groups.values),
        tax_rate_groups: groups.values,
        rounding_mode: rounding_mode,
        rounding_scope: :per_tax_rate_group,
        warnings: ([ :tax_detail_mismatch ] + payment_warnings(payment)).uniq,
        evidence: detected_tax_details.map { |detail| detail[:evidence] } + payment[:evidence],
        computed_items: items,
        calculation_profile: calculation_profile(
          receipt_tax_basis: :tax_added_to_subtotal,
          item_amount_basis: :line_total_as_net,
          tax_detail_amount_basis: :net
        ),
        source: :amount_engine
      )
    end

    def mixed_candidates
      return [] unless final_detected_tax_details.present?

      tax_rounding_modes.map do |rounding_mode|
        mixed_candidate(rounding_mode)
      end.compact
    end

    def mixed_candidate(rounding_mode)
      targets = tax_detail_targets_by_rate
      return nil if targets.blank?

      computed_items = Array.new(items.size)
      groups = {}
      warnings = adjustment_warnings.dup
      exact = true
      mixed_basis_used = false
      evidence = final_detected_tax_details.map { |detail| detail[:evidence] }
      profile_assignments = []
      purchase_adjustment_groups = purchase_adjustment_groups_by_rate(rounding_mode)

      indexed_items_by_rate.each do |rate, indexed_items|
        if rate.zero?
          gross = indexed_items.sum { |item, _index| item_line_total(item) }
          groups[rate] = { rate: rate, gross: gross, net: gross, tax: 0 }
          indexed_items.each { |item, index| computed_items[index] = item_with_line_total(item, item_line_total(item)) }
          profile_assignments << {
            tax_rate: BigDecimal("0"),
            basis: :non_taxable,
            net_amount: gross,
            tax_amount: 0,
            gross_amount: gross
          }
          next
        end

        target = targets[rate]
        adjustment_group = purchase_adjustment_groups[rate]
        unless target
          exact = false
          warnings << :item_tax_rate_group_uncertain
          indexed_items.each { |item, index| computed_items[index] = item_with_line_total(item, item_line_total(item)) }
          next
        end

        assignment_target = target_before_purchase_adjustments(target, adjustment_group)
        assignment = item_level_assignment_for(indexed_items, assignment_target, rate, rounding_mode)
        unless assignment[:status] == :exact
          exact = false
          warnings << :price_tax_inclusion_uncertain
          indexed_items.each { |item, index| computed_items[index] = item_with_line_total(item, item_line_total(item)) }
          groups[rate] = target.slice(:rate, :gross, :net, :tax)
          next
        end

        groups[rate] = {
          rate: rate,
          gross: target[:gross],
          net: target[:net],
          tax: target[:tax]
        }
        assignment[:assignments].each do |entry|
          computed_items[entry[:index]] = item_with_line_total(
            items[entry[:index]],
            entry[:gross_amount],
            normalize_price: entry[:basis] == :tax_excluded
          )
          profile_assignments << {
            tax_rate: entry[:rate],
            basis: entry[:basis],
            net_amount: entry[:net_amount],
            tax_amount: entry[:tax_amount],
            gross_amount: entry[:gross_amount]
          }
        end
        mixed_basis_used ||= assignment[:assignments].any? { |entry| entry[:basis] == :tax_excluded }
        evidence.concat(assignment[:assignments].map { |entry| entry.slice(:source, :index, :basis, :rate, :net_amount, :tax_amount, :gross_amount) })
      end

      targets.each do |rate, target|
        next if groups.key?(rate)

        groups[rate] = target.slice(:rate, :gross, :net, :tax)
      end

      purchase_total = groups.values.sum { |group| group[:gross] } +
        unapplied_purchase_adjustment_total(purchase_adjustment_groups, groups.keys)
      tax = groups.values.sum { |group| group[:tax] }
      warnings << :price_tax_inclusion_uncertain if mixed_basis_used && !receipt_amounts_match_candidate?(purchase_total, tax)
      payment = payment_reconciliation(purchase_total, payment_adjustment_total)
      warnings += payment_warnings(payment)

      Amounts::Candidate.new(
        candidate_id: "mixed_by_tax_rate_group/#{rounding_mode}",
        basis: "mixed_by_tax_rate_group",
        subtotal: purchase_total - tax,
        tax: tax,
        purchase_total: purchase_total,
        final_payment_total: payment[:final_payment_total],
        purchase_adjustment_total: purchase_adjustment_total,
        payment_adjustment_total: payment_adjustment_total,
        payment_amount_sum: payment[:payment_amount_sum],
        tax_details: tax_details_from_groups(groups.values),
        tax_rate_groups: groups.values,
        rounding_mode: rounding_mode,
        rounding_scope: :per_tax_rate_group,
        warnings: warnings.uniq,
        hard_reject_reasons: exact ? [] : [ :tax_detail_mismatch ],
        evidence: evidence + adjustment_evidence + payment[:evidence] + [ { source: "amount_engine", formula: "mixed_by_tax_rate_group", purchase_total: purchase_total } ],
        computed_items: computed_items.map.with_index { |item, index| item || item_with_line_total(items[index], item_line_total(items[index])) },
        calculation_profile: mixed_calculation_profile(profile_assignments),
        source: :amount_engine
      )
    end

    def purchase_adjustment_groups_by_rate(rounding_mode)
      classified_adjustments.each_with_object({}) do |entry, groups|
        classification = entry[:classification]
        next if classification[:effect] == :payment_adjustment

        rate = classification[:tax_rate]
        signed_amount = classification[:signed_amount].to_i
        next if signed_amount.zero?

        tax = rate.positive? ? signed_tax_from_gross(signed_amount, rate, rounding_mode) : 0
        groups[rate] ||= { rate: rate, gross: 0, net: 0, tax: 0 }
        groups[rate][:gross] += signed_amount
        groups[rate][:net] += signed_amount - tax
        groups[rate][:tax] += tax
      end
    end

    def target_before_purchase_adjustments(target, adjustment_group)
      return target unless adjustment_group

      {
        rate: target[:rate],
        gross: target[:gross] - adjustment_group[:gross],
        net: target[:net] - adjustment_group[:net],
        tax: target[:tax] - adjustment_group[:tax]
      }
    end

    def unapplied_purchase_adjustment_total(purchase_adjustment_groups, applied_rates)
      purchase_adjustment_groups.sum do |rate, group|
        applied_rates.include?(rate) ? 0 : group[:gross]
      end
    end

    def item_level_assignment_for(indexed_items, target, rate, rounding_mode)
      return { status: :search_limited, assignments: [] } if indexed_items.size > SAME_RATE_MIXED_MAX_ITEMS

      states = { [ 0, 0, 0 ] => [ [] ] }
      indexed_items.each do |item, index|
        candidates = item_level_basis_candidates(item, index, rate, rounding_mode)
        next_states = {}

        states.each do |(net_sum, tax_sum, gross_sum), paths|
          candidates.each do |candidate|
            next_key = [
              net_sum + candidate[:net_amount],
              tax_sum + candidate[:tax_amount],
              gross_sum + candidate[:gross_amount]
            ]
            next if next_key[0] > target[:net] || next_key[1] > target[:tax] || next_key[2] > target[:gross]

            next_states[next_key] ||= []
            paths.each do |path|
              next_states[next_key] << (path + [ candidate ])
              next_states[next_key] = next_states[next_key].first(2)
            end
          end
        end

        return { status: :search_limited, assignments: [] } if next_states.size > SAME_RATE_MIXED_MAX_STATES
        return { status: :no_exact, assignments: [] } if next_states.blank?

        states = next_states
      end

      matches = states[[ target[:net], target[:tax], target[:gross] ]] || []
      return { status: :ambiguous, assignments: [] } if matches.many?
      return { status: :no_exact, assignments: [] } if matches.blank?

      {
        status: :exact,
        assignments: matches.first,
        net: target[:net],
        tax: target[:tax],
        gross: target[:gross]
      }
    end

    def item_level_basis_candidates(item, index, rate, rounding_mode)
      line_total = item_line_total(item)
      return [] unless line_total.positive?

      included_tax = rounded_tax_from_gross(line_total, rate, rounding_mode)
      candidates = [
        {
          source: "receipt_items",
          index: index,
          rate: rate,
          basis: :tax_included,
          net_amount: line_total - included_tax,
          tax_amount: included_tax,
          gross_amount: line_total
        }
      ]
      return candidates unless tax_excluded_price_conversion_enabled?

      excluded_tax = Amounts::Rounding.apply_rounding(BigDecimal(line_total.to_s) * rate, rounding_mode)
      candidates << {
          source: "receipt_items",
          index: index,
          rate: rate,
          basis: :tax_excluded,
          net_amount: line_total,
          tax_amount: excluded_tax,
          gross_amount: line_total + excluded_tax
        }
      candidates
    end

    def tax_excluded_price_conversion_enabled?
      return true unless context.to_s.to_sym == :analysis

      tax_excluded_price_conversion_enabled
    end

    def item_basis_amounts(line_total, rate, item_basis, rounding_mode)
      return { gross_amount: line_total, net_amount: line_total, tax_amount: 0 } if rate <= 0

      case item_basis
      when :tax_excluded
        tax = Amounts::Rounding.apply_rounding(BigDecimal(line_total.to_s) * rate, rounding_mode)
        { gross_amount: line_total + tax, net_amount: line_total, tax_amount: tax }
      else
        tax = rounded_tax_from_gross(line_total, rate, rounding_mode)
        { gross_amount: line_total, net_amount: line_total - tax, tax_amount: tax }
      end
    end

    def build_tax_rate_groups(groups, rounding_mode, rounding_scope, item_basis:)
      groups.values.map do |group|
        rate = group[:rate]
        if rate <= 0
          gross = group[:item_amounts].sum { |amounts| amounts[:gross_amount] }
          next { rate: rate, gross: gross, net: gross, tax: 0 }
        end

        gross, net, tax = rounded_group_amounts(group[:item_amounts], rate, rounding_mode, rounding_scope, item_basis: item_basis)
        { rate: rate, gross: gross, net: net, tax: tax }
      end
    end

    def rounded_group_amounts(amounts, rate, rounding_mode, rounding_scope, item_basis:)
      case rounding_scope
      when :per_item
        gross = amounts.sum { |amount| amount[:gross_amount] }
        tax = amounts.sum { |amount| amount[:tax_amount] }
        [ gross, gross - tax, tax ]
      else
        if item_basis == :tax_excluded
          net = amounts.sum { |amount| amount[:net_amount] }
          tax = Amounts::Rounding.apply_rounding(BigDecimal(net.to_s) * rate, rounding_mode)
          [ net + tax, net, tax ]
        else
          gross = amounts.sum { |amount| amount[:gross_amount] }
          tax = rounded_tax_from_gross(gross, rate, rounding_mode)
          [ gross, gross - tax, tax ]
        end
      end
    end

    def discounted_original_line_total_tax_excluded_candidate_needed?
      context.to_s.to_sym == :analysis &&
        items.any? { |item| discounted_original_line_total_for(item) }
    end

    def item_basis_line_total(item, item_basis:, line_total_source:)
      return item_line_total(item) unless item_basis == :tax_excluded
      return item_line_total(item) unless line_total_source == :discounted_original_line_total

      discounted_original_line_total_for(item) || item_line_total(item)
    end

    def discounted_original_line_total_for(item)
      item = indifferent_hash(item)
      return nil unless discount_applied?(item)

      original_line_total = to_i(item[:original_line_total])
      current_line_total = item_line_total(item)
      return nil unless original_line_total.positive?
      return nil unless current_line_total.positive?
      return nil unless original_line_total > current_line_total

      original_line_total
    end

    def non_taxable_item_total_for_printed_tax_details(tax_detail_groups)
      explicit = explicit_non_taxable_items.sum { |item| item_line_total(item) }
      unknown = unknown_tax_rate_items.sum { |item| item_line_total(item) }
      return explicit if tax_detail_purchase_total_matches_item_total?(tax_detail_groups)
      return explicit if tax_detail_purchase_total_matches_receipt_total?(tax_detail_groups)

      explicit + unknown
    end

    def tax_detail_purchase_total_matches_item_total?(tax_detail_groups)
      tax_detail_purchase_total = Array(tax_detail_groups).sum { |group| group[:gross].to_i }
      tax_detail_purchase_total.positive? && tax_detail_purchase_total == item_total
    end

    def tax_detail_purchase_total_matches_receipt_total?(tax_detail_groups)
      receipt_total = amount_or_nil(receipt[:total_amount])
      return false unless receipt_total&.positive?

      tax_detail_purchase_total = Array(tax_detail_groups).sum { |group| group[:gross].to_i }
      tax_detail_purchase_total.positive? && tax_detail_purchase_total == receipt_total
    end

    def adjusted_item_total
      [ item_total + purchase_adjustment_total, 0 ].max
    end

    def item_tax_rates_missing?
      items.present? && items.all? do |item|
        item = indifferent_hash(item)
        !value_present?(item[:tax_rate])
      end
    end

    def incomplete_tax_detail_amounts_present?
      incomplete_source_tax_details.present?
    end

    def incomplete_source_tax_details
      @incomplete_source_tax_details ||= detected_tax_details.filter_map do |detail|
        next unless detail[:amount].to_i.positive?
        next if detail[:rate].positive? && detail[:net_amount].to_i.positive?

        {
          description: detail[:description],
          rate: nil,
          net_amount: nil,
          amount: detail[:amount]
        }
      end
    end

    def incomplete_tax_detail_evidence
      incomplete_source_tax_details.map.with_index do |detail, index|
        {
          source: "receipt_tax_detail",
          index: index,
          basis: :tax_only,
          description: detail[:description],
          amount: detail[:amount]
        }
      end
    end

    def printed_tax_detail_item_amount_basis(basis, purchase_total)
      return :line_total_as_recorded unless basis == "external_tax_from_receipt"
      return :line_total_as_net if strict_external_tax_receipt_amounts_match?(purchase_total)

      :line_total_as_recorded
    end

    def strict_external_tax_receipt_amounts_match?(purchase_total)
      subtotal = amount_or_nil(receipt[:subtotal_amount])
      tax = amount_or_nil(receipt[:tax_amount])
      total = amount_or_nil(receipt[:total_amount])

      !subtotal.nil? &&
        !tax.nil? &&
        !total.nil? &&
        subtotal + tax == total &&
        total == purchase_total.to_i
    end

    def receipt_amounts_match_candidate?(purchase_total, tax)
      subtotal = amount_or_nil(receipt[:subtotal_amount])
      receipt_tax = amount_or_nil(receipt[:tax_amount])
      total = amount_or_nil(receipt[:total_amount])

      !subtotal.nil? &&
        !receipt_tax.nil? &&
        !total.nil? &&
        subtotal == purchase_total.to_i - tax.to_i &&
        receipt_tax == tax.to_i &&
        total == purchase_total.to_i
    end

    def explicit_non_taxable_items
      items.select do |item|
        item = indifferent_hash(item)
        value_present?(item[:tax_rate]) && normalize_rate(item[:tax_rate]).zero?
      end
    end

    def unknown_tax_rate_items
      items.select do |item|
        item = indifferent_hash(item)
        !value_present?(item[:tax_rate]) && item_tax_rate(item).zero?
      end
    end

    def item_candidate_line_total_source(line_total_source)
      return nil if line_total_source == :line_total

      line_total_source
    end

    def item_candidate_calculation_profile(line_total_source)
      source = item_candidate_line_total_source(line_total_source)
      return calculation_profile unless source

      calculation_profile(line_total_source: source)
    end

    def calculation_profile(attributes = {})
      { discount_rounding_mode: discount_rounding_mode }.merge(attributes).compact
    end

    def mixed_calculation_profile(assignments)
      bases = Array(assignments).map { |assignment| assignment[:basis] }.uniq
      positive_rates = Array(assignments).filter_map do |assignment|
        rate = assignment[:tax_rate]
        rate if rate.respond_to?(:positive?) && rate.positive?
      end.uniq
      return calculation_profile(receipt_tax_basis: :total_includes_tax, item_amount_basis: :line_total_as_recorded, tax_detail_amount_basis: :gross) unless positive_rates.many? || bases.include?(:non_taxable)
      return calculation_profile(receipt_tax_basis: :total_includes_tax, item_amount_basis: :line_total_as_recorded, tax_detail_amount_basis: :gross) unless bases.many? && (bases & %i[tax_included tax_excluded]).any?

      calculation_profile(
        receipt_tax_basis: :total_includes_tax,
        item_amount_basis: :mixed_by_tax_rate_group,
        tax_detail_amount_basis: :gross,
        item_amount_basis_assignments: assignments
      )
    end

    def apply_purchase_adjustments_to_groups!(groups, item_basis:, rounding_mode:)
      classified_adjustments.each do |entry|
        classification = entry[:classification]
        next if classification[:effect] == :payment_adjustment

        rate = classification[:tax_rate]
        groups[rate] ||= { rate: rate, item_amounts: [] }
        amount = classification[:signed_amount]
        groups[rate][:item_amounts] << if item_basis == :tax_excluded && rate.positive?
          tax = signed_tax_from_net(amount, rate, rounding_mode)
          { gross_amount: amount + tax, net_amount: amount, tax_amount: tax }
        else
          tax = rate.positive? ? signed_tax_from_gross(amount, rate, rounding_mode) : 0
          { gross_amount: amount, net_amount: amount - tax, tax_amount: tax }
        end
      end
    end

    def signed_tax_from_net(signed, rate, rounding_mode)
      sign = signed.negative? ? -1 : 1
      sign * Amounts::Rounding.apply_rounding(BigDecimal(signed.abs.to_s) * rate, rounding_mode)
    end

    def signed_tax_from_gross(signed, rate, rounding_mode)
      sign = signed.negative? ? -1 : 1
      sign * rounded_tax_from_gross(signed.abs, rate, rounding_mode)
    end

    def tax_detail_targets_by_rate
      final_detected_tax_details.each_with_object({}) do |detail, hash|
        rate = detail[:rate]
        next unless rate.positive?

        hash[rate] ||= { rate: rate, gross: 0, net: 0, tax: 0 }
        hash[rate][:gross] += detail[:target_gross_amount].to_i
        hash[rate][:net] += detail[:target_net_amount].to_i
        hash[rate][:tax] += detail[:amount].to_i
      end
    end

    def tax_detail_amounts_for(detail, amount_basis)
      basis = amount_basis == :detected ? detail[:basis] : amount_basis
      case basis
      when :gross
        tax = detail[:amount].to_i
        gross = detail[:net_amount].to_i
        { gross: gross, net: [ gross - tax, 0 ].max, tax: tax }
      else
        net = detail[:net_amount].to_i
        tax = detail[:amount].to_i
        { gross: net + tax, net: net, tax: tax }
      end
    end

    def gross_tax_detail_candidate?(amount_basis)
      return true if amount_basis == :gross
      return false unless amount_basis == :detected

      final_detected_tax_details.present? && final_detected_tax_details.all? { |detail| detail[:basis] == :gross }
    end

    def tax_detail_purchase_adjustment_total(groups, gross_basis:)
      return 0 if purchase_adjustment_total.zero?
      return purchase_adjustment_total unless item_total.positive?

      detail_gross_total = Array(groups).sum { |group| group[:gross].to_i }
      receipt_total = amount_or_nil(receipt[:total_amount])
      return 0 if receipt_total&.positive? && detail_gross_total == receipt_total

      basis_total = Array(groups).sum { |group| gross_basis ? group[:gross].to_i : group[:net].to_i }
      adjusted_item_total = [ item_total + purchase_adjustment_total, 0 ].max

      return 0 if basis_total == adjusted_item_total
      return purchase_adjustment_total if basis_total == item_total

      purchase_adjustment_total
    end

    def tax_details_from_groups(groups)
      Array(groups).filter_map do |group|
        rate = group[:rate]
        next if rate <= 0

        {
          description: description_for(rate),
          rate: rate,
          net_amount: group[:net],
          amount: group[:tax]
        }
      end
    end

    def tax_details_from_printed_groups(groups, gross_basis:)
      return tax_details_from_groups(groups) unless gross_basis

      Array(groups).filter_map do |group|
        rate = group[:rate]
        next if rate <= 0

        {
          description: description_for(rate),
          rate: rate,
          net_amount: group[:net],
          amount: group[:tax]
        }
      end
    end

    def description_for(rate)
      percentage = rate * 100
      formatted = percentage.frac.zero? ? percentage.to_i.to_s : percentage.to_s("F")
      "#{formatted}%対象"
    end

    def payment_reconciliation(purchase_total, payment_adjustment_total)
      Amounts::PaymentReconciler.new(
        payments: payments,
        purchase_total: purchase_total,
        payment_adjustment_total: payment_adjustment_total
      ).call
    end

    def payment_warnings(payment)
      warnings = Array(payment[:warnings])
      return warnings unless context.to_s.to_sym == :analysis
      return warnings if payment[:payment_delta].to_i.negative?

      []
    end

    def purchase_adjustment_total
      @purchase_adjustment_total ||= classified_adjustments.sum do |entry|
        entry[:classification][:effect] == :payment_adjustment ? 0 : entry[:classification][:signed_amount]
      end
    end

    def payment_adjustment_total
      @payment_adjustment_total ||= classified_adjustments.sum do |entry|
        entry[:classification][:effect] == :payment_adjustment ? entry[:classification][:signed_amount] : 0
      end
    end

    def adjustment_warnings
      @adjustment_warnings ||= classified_adjustments.flat_map { |entry| entry[:classification][:warnings] }.uniq
    end

    def adjustment_evidence
      @adjustment_evidence ||= classified_adjustments.map { |entry| entry[:classification][:evidence] }
    end

    def classified_adjustments
      @classified_adjustments ||= adjustments.map do |adjustment|
        {
          adjustment: adjustment,
          classification: Amounts::AdjustmentClassifier.call(adjustment)
        }
      end
    end

    def indexed_items_by_rate
      items.each_with_index.group_by { |item, _index| item_tax_rate(item) }
    end

    def detected_tax_details
      @detected_tax_details ||= Amounts::TaxDetailBasisDetector.call(tax_details)
    end

    def final_detected_tax_details
      @final_detected_tax_details ||= detected_tax_details.select do |detail|
        %i[gross net].include?(detail[:basis]) &&
          detail[:rate].positive? &&
          detail[:net_amount].to_i.positive? &&
          detail[:amount].to_i.positive?
      end
    end

    def empty_groups
      Hash.new do |hash, rate|
        hash[rate] = { rate: rate, item_amounts: [] }
      end
    end

    def item_with_line_total(item, line_total, normalize_price: false)
      item = indifferent_hash(item)
      normalized = item.merge(line_total: line_total)

      if normalize_price
        price = normalized_unit_price_for(item, line_total)
        normalized[:price] = price unless price.nil?
      end

      normalized
    end

    def normalized_unit_price_for(item, line_total)
      line_total = to_i(line_total)
      return nil unless line_total.positive?
      return nil if discount_applied?(item)

      quantity = Amounts::NumberParser.parse_quantity(item[:quantity], default: BigDecimal("1"))
      quantity = BigDecimal("1") if quantity <= 0
      return nil unless quantity.frac.zero?
      return nil unless default_or_countable_quantity_unit?(item[:quantity_unit])

      quantity_integer = quantity.to_i
      return nil unless quantity_integer.positive?
      return nil unless (line_total % quantity_integer).zero?

      line_total / quantity_integer
    end

    def discount_applied?(item)
      to_i(item[:discount_amount]).positive? || normalize_rate(item[:discount_rate]).positive?
    end

    def default_or_countable_quantity_unit?(unit)
      unit.to_s.strip.blank? || countable_quantity_unit?(unit)
    end

    def item_line_total(item)
      item = indifferent_hash(item)
      return to_i(item[:line_total]) if present?(item[:line_total])
      return 0 unless countable_quantity_unit?(item[:quantity_unit])

      price = to_i(item[:price])
      quantity = Amounts::NumberParser.parse_quantity(item[:quantity])
      quantity = BigDecimal("1") if quantity <= 0
      (BigDecimal(price.to_s) * quantity).round(0).to_i
    end

    def item_total
      @item_total ||= items.sum { |item| item_line_total(item) }
    end

    def item_data_present?
      items.any? do |item|
        normalized = indifferent_hash(item)
        item_line_total(normalized).positive? ||
          explicit_zero_amount_item?(normalized) ||
          to_i(normalized[:original_line_total]).positive? ||
          to_i(normalized[:discount_amount]).positive?
      end
    end

    def explicit_zero_amount_item?(item)
      explicit_zero_line_total?(item) || explicit_zero_price_total?(item)
    end

    def explicit_zero_line_total?(item)
      value_was_present?(item, :line_total) && to_i(item[:line_total]).zero?
    end

    def explicit_zero_price_total?(item)
      value_was_present?(item, :price) && to_i(item[:price]).zero?
    end

    def value_was_present?(item, key)
      flag = item[:"amount_#{key}_present"]
      return flag if [ true, false ].include?(flag)

      present?(item[key])
    end

    def item_tax_rate(item)
      normalized = indifferent_hash(item)
      return BigDecimal("0") if non_taxable_item_text?(normalized)

      rate = normalize_rate(normalized[:tax_rate])
      return rate if rate.positive?
      return BigDecimal("0") if value_present?(normalized[:tax_rate]) && rate.zero?

      fallback_tax_rate
    end

    def non_taxable_item_text?(item)
      text = [
        item[:raw_text],
        item[:suggested_name],
        item[:confirmed_name],
        item[:name]
      ].compact.join(" ").unicode_normalize(:nfkc)

      text.match?(/非課税|非課稅|non.?tax|tax.?free/i)
    end

    def fallback_tax_rate
      @fallback_tax_rate ||= begin
        detail_rates = final_detected_tax_details.map { |detail| detail[:rate] }.uniq
        detail_rates.one? ? detail_rates.first : BigDecimal("0")
      end
    end

    def countable_quantity_unit?(unit)
      return true unless defined?(ReceiptItem::COUNTABLE_QUANTITY_UNITS)

      ReceiptItem::COUNTABLE_QUANTITY_UNITS.include?(unit.to_s.strip)
    end

    def rounded_tax_from_gross(gross_total, rate, rounding_mode)
      Amounts::Rounding.apply_rounding(BigDecimal(gross_total.to_s) * rate / (BigDecimal("1") + rate), rounding_mode)
    end

    def normalize_rate(value)
      return BigDecimal("0") if value.nil? || value == ""

      rate = BigDecimal(value.to_s.delete("%"))
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError
      BigDecimal("0")
    end

    def normalize_rounding_modes(values)
      Array(values).map { |value| Amounts::Rounding.normalize_rounding_mode(value) }.uniq
    end

    def indifferent_hash(value)
      if value.respond_to?(:with_indifferent_access)
        value.with_indifferent_access
      elsif value.respond_to?(:to_h)
        value.to_h.with_indifferent_access
      else
        {}.with_indifferent_access
      end
    end

    def to_i(value)
      Amounts::NumberParser.parse_amount(value)
    end

    def amount_or_nil(value)
      Amounts::NumberParser.parse_amount_or_nil(value)
    end

    def present?(value)
      !value.nil? && value != ""
    end

    def value_present?(value)
      present?(value)
    end

    def fetch_value(object, key)
      if object.respond_to?(:key?)
        return object[key] if object.key?(key)
        object[key.to_s] if object.key?(key.to_s)
      elsif object.respond_to?(key)
        object.public_send(key)
      end
    end
  end
end
