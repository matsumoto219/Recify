# frozen_string_literal: true

module Amounts
  class CalculationProfileEstimator
    ROUNDING_MODES = %i[floor round ceil].freeze
    RECEIPT_TAX_BASES = %i[total_includes_tax tax_added_to_subtotal].freeze
    ITEM_AMOUNT_BASES = %i[line_total_as_recorded line_total_as_net mixed_by_tax_rate_group].freeze
    DEFAULT_ITEM_AMOUNT_BASIS = :line_total_as_recorded
    UNCERTAIN_SCORE_GAP = 100
    SAME_RATE_MIXED_MAX_ITEMS = 20
    SAME_RATE_MIXED_MAX_STATES = 50_000

    def initialize(receipt:, items:, tax_details:, context: :analysis, tax_rounding_modes: nil, discount_rounding_modes: nil, receipt_tax_bases: RECEIPT_TAX_BASES, item_amount_bases: ITEM_AMOUNT_BASES)
      @receipt = receipt
      @items = Array(items)
      @tax_details = Array(tax_details)
      @context = normalize_context(context)
      @tax_rounding_modes = normalize_rounding_modes(tax_rounding_modes, ROUNDING_MODES)
      @discount_rounding_modes = normalize_rounding_modes(discount_rounding_modes, ROUNDING_MODES)
      @receipt_tax_bases = normalize_receipt_tax_bases(receipt_tax_bases)
      @item_amount_bases = normalize_item_amount_bases(item_amount_bases)
    end

    def call
      return empty_result unless @context == :analysis

      candidates = profiles.map { |profile| candidate_for(profile) }
      candidates.sort_by! { |candidate| sort_key(candidate) }

      best = candidates.first

      {
        profile: best&.fetch(:profile, nil),
        score: best&.fetch(:score, nil),
        candidates: candidates,
        warnings: warnings_for(candidates)
      }
    end

    private

    def profiles
      @tax_rounding_modes.product(@discount_rounding_modes, @receipt_tax_bases, @item_amount_bases).map do |tax_rounding_mode, discount_rounding_mode, receipt_tax_basis, item_amount_basis|
        {
          tax_rounding_mode: tax_rounding_mode,
          discount_rounding_mode: discount_rounding_mode,
          receipt_tax_basis: receipt_tax_basis,
          item_amount_basis: item_amount_basis
        }
      end
    end

    def candidate_for(profile)
      profile = profile_with_metadata(profile)
      calc = Amounts::Calculator.new(
        receipt: @receipt,
        items: @items,
        tax_details: @tax_details,
        context: @context,
        tax_rounding_mode: profile[:tax_rounding_mode],
        discount_rounding_mode: profile[:discount_rounding_mode],
        receipt_tax_basis: profile[:receipt_tax_basis],
        item_amount_basis: profile[:item_amount_basis],
        item_amount_basis_assignments: profile[:item_amount_basis_assignments]
      ).call

      deltas = deltas_for(calc, profile)

      candidate = {
        profile: profile,
        score: score_for(deltas, profile),
        deltas: deltas
      }

      same_rate_assignment = same_rate_item_assignment_for(profile[:tax_rounding_mode])
      if profile[:item_amount_basis] == :mixed_by_tax_rate_group && same_rate_assignment[:exact]
        candidate[:same_rate_item_amount_basis_assignments] = same_rate_assignment[:assignments]
      end

      candidate
    end

    def deltas_for(calc, profile)
      amounts = profile_amounts(calc, profile)

      {
        total: amount_delta(amounts[:total], :total_amount),
        subtotal: amount_delta(amounts[:subtotal], :subtotal_amount),
        tax: amount_delta(amounts[:tax], :tax_amount),
        tax_details: tax_detail_delta(calc, profile),
        item_line_total: item_line_total_delta(calc[:items]),
        discount: discount_delta(profile[:discount_rounding_mode]),
        basis_relation: basis_relation_delta(calc, profile, amounts)
      }
    end

    def score_for(deltas, profile)
      deltas[:total] * 100 +
        deltas[:tax] * 80 +
        deltas[:subtotal] * 50 +
        deltas[:tax_details] * 80 +
        deltas[:item_line_total] * 40 +
        deltas[:discount] * 40 +
        deltas[:basis_relation] * 100 +
        receipt_tax_basis_penalty(profile) +
        item_amount_basis_penalty(profile[:item_amount_basis])
    end

    def receipt_tax_basis_penalty(profile)
      receipt_tax_basis = profile[:receipt_tax_basis]
      return 25 if profile[:item_amount_basis] == :mixed_by_tax_rate_group && receipt_tax_basis == :tax_added_to_subtotal && !explicit_external_tax_evidence?
      return 10_000 if receipt_tax_basis == :tax_added_to_subtotal && !external_tax_candidate_available?

      0
    end

    def item_amount_basis_penalty(item_amount_basis)
      case item_amount_basis
      when :line_total_as_recorded
        explicit_external_tax_evidence? ? 25 : 0
      when :line_total_as_net
        explicit_external_tax_evidence? ? 0 : 25
      when :mixed_by_tax_rate_group
        mixed_assignment_exact? ? 0 : (mixed_item_amount_basis_suspected? ? 25 : 1_000)
      else
        1_000
      end
    end

    def sort_key(candidate)
      profile = candidate[:profile]

      [
        candidate[:score],
        receipt_tax_basis_priority(profile[:receipt_tax_basis]),
        item_amount_basis_priority(profile[:item_amount_basis]),
        tax_rounding_priority(profile[:tax_rounding_mode]),
        discount_rounding_priority(profile[:discount_rounding_mode])
      ]
    end

    def amount_delta(computed_value, receipt_key)
      printed_value = Amounts::NumberParser.parse_amount_or_nil(fetch_value(@receipt, receipt_key))
      return 0 if printed_value.nil?

      (to_i(computed_value) - printed_value).abs
    end

    def tax_detail_delta(calc, profile)
      source_groups = tax_details_by_rate(complete_tax_details)
      return 0 if source_groups.blank?

      generated_groups = tax_details_by_rate(generated_tax_details(calc, profile))
      rates = source_groups.keys | generated_groups.keys

      rates.sum do |rate|
        source = source_groups[rate] || { amount: 0, net_amount: 0 }
        generated = generated_groups[rate] || { amount: 0, net_amount: 0 }

        (source[:amount] - generated[:amount]).abs +
          (source[:net_amount] - generated[:net_amount]).abs
      end
    end

    def generated_tax_details(calc, profile)
      if profile[:item_amount_basis] == :mixed_by_tax_rate_group && profile[:item_amount_basis_assignments].present?
        return mixed_generated_tax_details(profile[:item_amount_basis_assignments])
      end

      if profile[:item_amount_basis] == :line_total_as_net
        generated = tax_excluded_tax_details(profile[:tax_rounding_mode])
        return generated if generated.present?
      end

      if calc[:external_tax] || calc[:tax_details_primary]
        return complete_tax_details
      end

      Amounts::TaxDetailAggregator.new(
        items: calc[:items],
        fallback_tax_rate: calc[:tax_rate],
        fallback_net_amount: calc[:subtotal],
        fallback_tax_amount: calc[:tax],
        rounding_mode: profile[:tax_rounding_mode]
      ).call
    end

    def profile_amounts(calc, profile)
      if profile[:item_amount_basis] == :mixed_by_tax_rate_group && profile[:item_amount_basis_assignments].present?
        return mixed_amounts(profile[:item_amount_basis_assignments])
      end

      return tax_excluded_amounts(profile[:tax_rounding_mode]) if profile[:item_amount_basis] == :line_total_as_net

      {
        subtotal: calc[:subtotal],
        tax: calc[:tax],
        total: calc[:total]
      }
    end

    def tax_excluded_amounts(tax_rounding_mode)
      subtotal = source_item_total
      tax = tax_excluded_tax_details(tax_rounding_mode).sum { |tax_detail| to_i(fetch_value(tax_detail, :amount)) }

      {
        subtotal: subtotal,
        tax: tax,
        total: subtotal + tax
      }
    end

    def tax_excluded_tax_details(tax_rounding_mode)
      groups = @items.each_with_object({}) do |item, hash|
        line_total = source_item_line_total(item)
        next unless line_total.positive?

        rate = normalize_rate(fetch_value(item, :tax_rate))
        rate = fallback_tax_rate if rate <= 0
        next if rate <= 0

        hash[rate] ||= { rate: rate, net_amount: 0, amount: 0 }
        hash[rate][:net_amount] += line_total
        hash[rate][:amount] += Amounts::Rounding.apply_rounding(
          BigDecimal(line_total.to_s) * rate,
          tax_rounding_mode
        )
      end

      groups.values
    end

    def mixed_generated_tax_details(assignments)
      Array(assignments).filter_map do |assignment|
        rate = normalize_rate(fetch_value(assignment, :tax_rate))
        next if rate <= 0

        {
          rate: rate,
          net_amount: to_i(fetch_value(assignment, :net_amount)),
          amount: to_i(fetch_value(assignment, :tax_amount))
        }
      end
    end

    def mixed_amounts(assignments)
      {
        subtotal: Array(assignments).sum { |assignment| to_i(fetch_value(assignment, :net_amount)) },
        tax: Array(assignments).sum { |assignment| to_i(fetch_value(assignment, :tax_amount)) },
        total: Array(assignments).sum { |assignment| to_i(fetch_value(assignment, :gross_amount)) }
      }
    end

    def item_line_total_delta(calculated_items)
      Array(calculated_items).each_with_index.sum do |calculated_item, index|
        source_item = @items[index]
        next 0 unless present?(fetch_value(source_item, :line_total))

        (to_i(fetch_value(calculated_item, :line_total)) - to_i(fetch_value(source_item, :line_total))).abs
      end
    end

    def discount_delta(discount_rounding_mode)
      @items.sum do |item|
        original_line_total = to_i(fetch_value(item, :original_line_total))
        discount_amount = to_i(fetch_value(item, :discount_amount))
        discount_rate = normalize_rate(fetch_value(item, :discount_rate))

        next 0 unless original_line_total.positive?
        next 0 unless discount_amount.positive?
        next 0 unless discount_rate.positive?

        estimated_discount = Amounts::Rounding.apply_rounding(
          BigDecimal(original_line_total.to_s) * discount_rate,
          discount_rounding_mode
        )

        (estimated_discount - discount_amount).abs
      end
    end

    def basis_relation_delta(_calc, profile, amounts)
      return 0 if profile[:item_amount_basis] == :mixed_by_tax_rate_group && profile[:item_amount_basis_assignments].present?

      case profile[:receipt_tax_basis]
      when :tax_added_to_subtotal
        (source_item_total - to_i(amounts[:subtotal])).abs
      else
        (source_item_total - to_i(amounts[:total])).abs
      end
    end

    def complete_tax_details
      @tax_details.select do |tax_detail|
        normalize_rate(fetch_value(tax_detail, :rate)).positive? &&
          present?(fetch_value(tax_detail, :net_amount)) &&
          present?(fetch_value(tax_detail, :amount))
      end
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

    def external_tax_candidate_available?
      tax_detail_subtotal.positive? && tax_detail_total.positive?
    end

    def explicit_external_tax_evidence?
      @tax_details.any? do |tax_detail|
        fetch_value(tax_detail, :description).to_s.match?(/外税|税別|消費税別|別途消費税/)
      end
    end

    def external_tax_preferred?
      return false unless external_tax_candidate_available?

      receipt_total = Amounts::NumberParser.parse_amount_or_nil(fetch_value(@receipt, :total_amount))
      return false unless receipt_total&.positive?

      source_item_total == tax_detail_subtotal &&
        receipt_total == tax_detail_subtotal + tax_detail_total
    end

    def source_item_total
      @source_item_total ||= @items.sum { |item| source_item_line_total(item) }
    end

    def source_item_line_total(item)
      line_total = fetch_value(item, :line_total)
      return to_i(line_total) if present?(line_total)

      original_line_total = to_i(fetch_value(item, :original_line_total))
      discount_amount = to_i(fetch_value(item, :discount_amount))
      return [ original_line_total - discount_amount, 0 ].max if original_line_total.positive?

      0
    end

    def tax_detail_subtotal
      @tax_detail_subtotal ||= complete_tax_details.sum { |tax_detail| to_i(fetch_value(tax_detail, :net_amount)) }
    end

    def tax_detail_total
      @tax_detail_total ||= complete_tax_details.sum { |tax_detail| to_i(fetch_value(tax_detail, :amount)) }
    end

    def fallback_tax_rate
      tax_detail_rates = complete_tax_details.filter_map do |tax_detail|
        rate = normalize_rate(fetch_value(tax_detail, :rate))
        rate.positive? ? rate : nil
      end.uniq

      return tax_detail_rates.first if tax_detail_rates.one?

      item_rates = @items.filter_map do |item|
        rate = normalize_rate(fetch_value(item, :tax_rate))
        rate.positive? ? rate : nil
      end.uniq

      item_rates.one? ? item_rates.first : BigDecimal("0")
    end

    def receipt_tax_basis_priority(receipt_tax_basis)
      if external_tax_preferred?
        receipt_tax_basis == :tax_added_to_subtotal ? 0 : 1
      else
        receipt_tax_basis == :total_includes_tax ? 0 : 1
      end
    end

    def item_amount_basis_priority(item_amount_basis)
      if explicit_external_tax_evidence?
        return { line_total_as_net: 0, line_total_as_recorded: 1, mixed_by_tax_rate_group: 2 }.fetch(item_amount_basis, 3)
      end

      return { mixed_by_tax_rate_group: 0, line_total_as_recorded: 1, line_total_as_net: 2 }.fetch(item_amount_basis, 3) if mixed_item_amount_basis_suspected?

      { line_total_as_recorded: 0, line_total_as_net: 1, mixed_by_tax_rate_group: 2 }.fetch(item_amount_basis, 3)
    end

    def tax_rounding_priority(tax_rounding_mode)
      { floor: 0, round: 1, ceil: 2 }.fetch(tax_rounding_mode, 3)
    end

    def discount_rounding_priority(discount_rounding_mode)
      { round: 0, floor: 1, ceil: 2 }.fetch(discount_rounding_mode, 3)
    end

    def normalize_rounding_modes(values, default)
      modes = values.nil? ? default : Array(values)
      modes.map { |value| Amounts::Rounding.normalize_rounding_mode(value) }.uniq
    end

    def normalize_receipt_tax_bases(values)
      Array(values).map { |value| value.to_s.to_sym }.select { |value| RECEIPT_TAX_BASES.include?(value) }.presence || RECEIPT_TAX_BASES
    end

    def normalize_item_amount_bases(values)
      Array(values).map { |value| value.to_s.to_sym }.select { |value| ITEM_AMOUNT_BASES.include?(value) }.presence || ITEM_AMOUNT_BASES
    end

    def profile_with_metadata(profile)
      return profile unless profile[:item_amount_basis] == :mixed_by_tax_rate_group

      assignment = mixed_assignment_for(profile[:tax_rounding_mode])
      return profile unless assignment[:exact]

      profile.merge(item_amount_basis_assignments: assignment[:assignments])
    end

    def warnings_for(candidates)
      warnings = []
      warnings << :calculation_profile_uncertain if calculation_profile_uncertain?(candidates)
      warnings << :price_tax_inclusion_uncertain if price_tax_inclusion_uncertain?(candidates) || same_rate_item_assignment_warning?
      warnings
    end

    def calculation_profile_uncertain?(candidates)
      best = candidates.first
      return false unless best

      candidates.any? do |candidate|
        next false unless candidate[:score].to_i == best[:score].to_i

        basis_changed?(best[:profile], candidate[:profile])
      end
    end

    def price_tax_inclusion_uncertain?(candidates)
      best = candidates.first
      return false unless best
      return false if best[:score].to_i.zero? && !mixed_profile_missing_receipt_amounts?(best[:profile])

      same_rate_mixed_assignment_uncertain? ||
        mixed_candidate_ranked_high?(candidates) ||
        tax_included_tax_excluded_close?(candidates)
    end

    def mixed_candidate_ranked_high?(candidates)
      best_score = candidates.first&.fetch(:score, nil).to_i

      candidates.any? do |candidate|
        next false if candidate[:score].to_i - best_score > UNCERTAIN_SCORE_GAP

        profile = candidate[:profile]
        profile[:item_amount_basis] == :mixed_by_tax_rate_group
      end
    end

    def tax_included_tax_excluded_close?(candidates)
      included_score = best_score_for_item_amount_basis(candidates, :line_total_as_recorded)
      excluded_score = best_score_for_item_amount_basis(candidates, :line_total_as_net)

      return false if included_score.nil? || excluded_score.nil?

      (included_score - excluded_score).abs <= UNCERTAIN_SCORE_GAP
    end

    def best_score_for_item_amount_basis(candidates, item_amount_basis)
      candidates
        .select { |candidate| candidate[:profile][:item_amount_basis] == item_amount_basis }
        .map { |candidate| candidate[:score].to_i }
        .min
    end

    def same_rate_mixed_assignment_uncertain?
      detail_groups = tax_details_by_rate(complete_tax_details)
      return false unless detail_groups.one?

      rate, detail = detail_groups.first
      item_rates = @items.filter_map do |item|
        item_rate = normalize_rate(fetch_value(item, :tax_rate))
        item_rate.positive? ? item_rate : nil
      end.uniq
      return false unless item_rates == [ rate ]

      group_total = @items.sum do |item|
        normalize_rate(fetch_value(item, :tax_rate)) == rate ? source_item_line_total(item) : 0
      end
      printed_gross = detail[:net_amount] + detail[:amount]

      detail[:net_amount] < group_total && group_total < printed_gross
    end

    def mixed_profile_missing_receipt_amounts?(profile)
      profile[:item_amount_basis] == :mixed_by_tax_rate_group && !receipt_amounts_complete?
    end

    def receipt_amounts_complete?
      present?(fetch_value(@receipt, :subtotal_amount)) &&
        present?(fetch_value(@receipt, :tax_amount)) &&
        present?(fetch_value(@receipt, :total_amount))
    end

    def basis_changed?(left, right)
      left[:item_amount_basis] != right[:item_amount_basis] || left[:receipt_tax_basis] != right[:receipt_tax_basis]
    end

    def mixed_item_amount_basis_suspected?
      return false unless source_item_total.positive?
      return true if tax_detail_subtotal.positive? && tax_detail_subtotal + tax_detail_total < source_item_total

      rates = @items.map { |item| normalize_rate(fetch_value(item, :tax_rate)) }.uniq
      rates.include?(BigDecimal("0")) && rates.any?(&:positive?)
    end

    def mixed_assignment_exact?
      ROUNDING_MODES.any? { |rounding_mode| mixed_assignment_for(rounding_mode)[:exact] }
    end

    def mixed_assignment_for(rounding_mode)
      @mixed_assignment_cache ||= {}
      @mixed_assignment_cache[rounding_mode] ||= build_mixed_assignment(rounding_mode)
    end

    def same_rate_item_assignment_for(rounding_mode)
      @same_rate_item_assignment_cache ||= {}
      @same_rate_item_assignment_cache[rounding_mode] ||= build_same_rate_item_assignment(rounding_mode)
    end

    def same_rate_item_assignment_warning?
      results = @tax_rounding_modes.map { |rounding_mode| same_rate_item_assignment_for(rounding_mode) }
      return false if results.any? { |result| same_rate_item_assignment_not_needed?(result) }
      return false if results.any? { |result| result[:exact] }

      results.any? { |result| result[:ambiguous] || result[:no_exact] || result[:search_limited] }
    end

    def same_rate_item_assignment_not_needed?(result)
      !result[:exact] &&
        !result[:ambiguous] &&
        !result[:no_exact] &&
        !result[:search_limited]
    end

    def build_mixed_assignment(rounding_mode)
      source_groups = @items.group_by { |item| normalize_rate(fetch_value(item, :tax_rate)) }
      detail_groups = tax_details_by_rate(complete_tax_details)
      assignments = []
      ambiguous = false

      source_groups.each do |rate, items|
        group_total = items.sum { |item| source_item_line_total(item) }
        next if group_total <= 0

        if rate <= 0
          assignments << {
            tax_rate: BigDecimal("0"),
            basis: :non_taxable,
            net_amount: group_total,
            tax_amount: 0,
            gross_amount: group_total
          }
          next
        end

        detail = detail_groups[rate]
        unless detail
          ambiguous = true
          next
        end

        matches = group_level_basis_candidates(group_total, rate, rounding_mode).select do |candidate|
          candidate[:net_amount] == detail[:net_amount] && candidate[:tax_amount] == detail[:amount]
        end

        if matches.one?
          assignments << matches.first
        else
          ambiguous = true
        end
      end

      source_positive_rates = source_groups.keys.select(&:positive?)
      ambiguous = true unless (detail_groups.keys - source_positive_rates).empty?

      basis_types = assignments.map { |assignment| assignment[:basis] }.uniq
      exact = !ambiguous &&
        assignments.any? &&
        basis_types.many? &&
        (basis_types & %i[tax_included tax_excluded]).any?

      {
        exact: exact,
        ambiguous: ambiguous,
        assignments: assignments
      }
    end

    def build_same_rate_item_assignment(rounding_mode)
      detail_groups = tax_details_by_rate(complete_tax_details)
      return empty_same_rate_item_assignment unless detail_groups.present?

      indexed_groups = @items.each_with_index.group_by do |item, _index|
        normalize_rate(fetch_value(item, :tax_rate))
      end
      assignments = []
      ambiguous = false
      no_exact = false
      search_limited = false

      detail_groups.each do |rate, detail|
        next unless rate.positive?

        indexed_items = indexed_groups[rate] || []
        next if indexed_items.size < 2

        group_total = indexed_items.sum { |item, _index| source_item_line_total(item) }
        next if group_total <= 0

        group_matches = group_level_basis_candidates(group_total, rate, rounding_mode).select do |candidate|
          candidate[:net_amount] == detail[:net_amount] && candidate[:tax_amount] == detail[:amount]
        end
        next if group_matches.one?

        result = item_level_assignment_for(
          indexed_items: indexed_items,
          detail: detail,
          rate: rate,
          rounding_mode: rounding_mode
        )

        case result[:status]
        when :exact
          assignments.concat(result[:assignments])
        when :ambiguous
          ambiguous = true
        when :search_limited
          search_limited = true
        else
          no_exact = true
        end
      end

      exact = assignments.present? && !ambiguous && !no_exact && !search_limited

      {
        exact: exact,
        ambiguous: ambiguous,
        no_exact: no_exact,
        search_limited: search_limited,
        assignments: exact ? assignments : []
      }
    end

    def item_level_assignment_for(indexed_items:, detail:, rate:, rounding_mode:)
      return { status: :search_limited, assignments: [] } if indexed_items.size > SAME_RATE_MIXED_MAX_ITEMS

      target_net = detail[:net_amount]
      target_tax = detail[:amount]
      states = { [ 0, 0 ] => [ [] ] }

      indexed_items.each do |item, index|
        candidates = item_level_basis_candidates(item, index, rate, rounding_mode)
        return { status: :no_exact, assignments: [] } if candidates.blank?

        next_states = {}
        states.each do |(net_sum, tax_sum), paths|
          candidates.each do |candidate|
            next_net = net_sum + candidate[:net_amount]
            next_tax = tax_sum + candidate[:tax_amount]
            next if next_net > target_net || next_tax > target_tax

            key = [ next_net, next_tax ]
            next_states[key] ||= []

            paths.each do |path|
              next_states[key] << (path + [ candidate ])
              next_states[key] = next_states[key].first(2)
            end
          end
        end

        return { status: :search_limited, assignments: [] } if next_states.size > SAME_RATE_MIXED_MAX_STATES
        return { status: :no_exact, assignments: [] } if next_states.blank?

        states = next_states
      end

      matches = states[[ target_net, target_tax ]] || []
      return { status: :exact, assignments: matches.first } if matches.one?
      return { status: :ambiguous, assignments: [] } if matches.many?

      { status: :no_exact, assignments: [] }
    end

    def group_level_basis_candidates(group_total, rate, rounding_mode)
      included_tax = rounded_tax_from_gross(group_total, rate, rounding_mode)
      excluded_tax = Amounts::Rounding.apply_rounding(BigDecimal(group_total.to_s) * rate, rounding_mode)

      [
        {
          tax_rate: rate,
          basis: :tax_included,
          net_amount: group_total - included_tax,
          tax_amount: included_tax,
          gross_amount: group_total
        },
        {
          tax_rate: rate,
          basis: :tax_excluded,
          net_amount: group_total,
          tax_amount: excluded_tax,
          gross_amount: group_total + excluded_tax
        }
      ]
    end

    def item_level_basis_candidates(item, index, rate, rounding_mode)
      line_total = source_item_line_total(item)
      return [] unless line_total.positive?

      included_tax = rounded_tax_from_gross(line_total, rate, rounding_mode)
      excluded_tax = Amounts::Rounding.apply_rounding(BigDecimal(line_total.to_s) * rate, rounding_mode)

      [
        {
          assignment_scope: :item,
          item_indices: [ index ],
          tax_rate: rate,
          basis: :tax_included,
          net_amount: line_total - included_tax,
          tax_amount: included_tax,
          gross_amount: line_total
        },
        {
          assignment_scope: :item,
          item_indices: [ index ],
          tax_rate: rate,
          basis: :tax_excluded,
          net_amount: line_total,
          tax_amount: excluded_tax,
          gross_amount: line_total + excluded_tax
        }
      ]
    end

    def empty_same_rate_item_assignment
      {
        exact: false,
        ambiguous: false,
        no_exact: false,
        search_limited: false,
        assignments: []
      }
    end

    def rounded_tax_from_gross(gross_total, tax_rate, rounding_mode)
      Amounts::Rounding.apply_rounding(BigDecimal(gross_total.to_s) * tax_rate / (BigDecimal("1") + tax_rate), rounding_mode)
    end

    def normalize_rate(value)
      return BigDecimal("0") unless present?(value)

      rate = BigDecimal(value.to_s.delete("%"))
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError
      BigDecimal("0")
    end

    def normalize_context(value)
      context = value.to_s.to_sym
      %i[analysis edit_save manual].include?(context) ? context : :analysis
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

    def to_i(value)
      Amounts::NumberParser.parse_amount(value)
    end

    def present?(value)
      !value.nil? && value != ""
    end

    def empty_result
      {
        profile: nil,
        score: nil,
        candidates: [],
        warnings: []
      }
    end
  end
end
