# frozen_string_literal: true

module Amounts
  class ProfileSummary
    class << self
      def call(selected_candidate:, candidates:, context:, receipt: {}, items: [], tax_details: [])
        new(
          selected_candidate: selected_candidate,
          candidates: candidates,
          context: context,
          receipt: receipt,
          items: items,
          tax_details: tax_details
        ).call
      end
    end

    def initialize(selected_candidate:, candidates:, context:, receipt: {}, items: [], tax_details: [])
      @selected_candidate = selected_candidate
      @candidates = Array(candidates)
      @context = context.to_s.to_sym
      @receipt = receipt || {}
      @items = Array(items)
      @tax_details = Array(tax_details)
    end

    def call
      return Amounts::CalculationProfileResult.new unless context == :analysis

      summary_candidates = profile_candidates
      best = summary_candidates.first

      Amounts::CalculationProfileResult.new(
        profile: best&.[](:profile),
        score: best&.[](:score),
        candidates: summary_candidates,
        warnings: profile_warnings
      )
    end

    private

    attr_reader :selected_candidate, :candidates, :context, :receipt, :items, :tax_details

    def profile_candidates
      profile_source_candidates.reject { |candidate| receipt_input_preserved_candidate?(candidate) }.filter_map do |candidate|
        summary_candidate_for(candidate)
      end
        .group_by { |candidate| candidate[:profile] }
        .values
        .map { |group| collapse_profile_candidate_group(group) }
        .sort_by { |candidate| [ candidate[:score].to_i, profile_sort_key(candidate[:profile]) ] }
    end

    def summary_candidate_for(candidate)
      {
        profile: profile_for(candidate),
        score: profile_score_for(candidate),
        deltas: deltas_for(candidate),
        same_rate_item_amount_basis_assignments: same_rate_item_amount_basis_assignments_for(candidate)
      }.compact
    end

    def collapse_profile_candidate_group(group)
      best = group.min_by { |candidate| candidate[:score].to_i }
      assignments = group.filter_map { |candidate| candidate[:same_rate_item_amount_basis_assignments] }.first
      return best unless assignments.present?

      best.merge(same_rate_item_amount_basis_assignments: assignments)
    end

    def receipt_input_preserved_candidate?(candidate)
      candidate.basis.to_s == "receipt_input_preserved"
    end

    def profile_source_candidates
      accepted = candidates.reject(&:rejected?)
      pool = accepted.presence || candidates
      explanatory_mixed = candidates.select do |candidate|
        candidate.rejected? &&
          candidate.basis.to_s == "mixed_by_tax_rate_group" &&
          mixed_item_amount_basis_suspected?
      end

      (pool + explanatory_mixed).uniq
    end

    def profile_for(candidate)
      profile = candidate_profile(candidate).dup
      if candidate.basis.to_s == "external_tax_from_receipt" &&
          profile[:item_amount_basis].to_s == "line_total_as_net" &&
          !explicit_external_tax_evidence?
        profile[:item_amount_basis] = :line_total_as_recorded
      end
      {
        tax_rounding_mode: candidate.rounding_mode,
        discount_rounding_mode: profile[:discount_rounding_mode] || Amounts::Rounding::DISCOUNT_DEFAULT_MODE,
        receipt_tax_basis: profile[:receipt_tax_basis] || receipt_tax_basis_for(candidate),
        item_amount_basis: profile[:item_amount_basis] || item_amount_basis_for(candidate),
        item_amount_basis_assignments: profile[:item_amount_basis_assignments]
      }.compact
    end

    def candidate_profile(candidate)
      raw_profile = candidate.calculation_profile
      return {} unless raw_profile.respond_to?(:to_h)

      raw_profile.to_h.symbolize_keys
    end

    def receipt_tax_basis_for(candidate)
      case candidate.basis
      when "external_tax_from_receipt", "items_as_tax_excluded", "printed_tax_details_net"
        :tax_added_to_subtotal
      else
        :total_includes_tax
      end
    end

    def item_amount_basis_for(candidate)
      case candidate.basis
      when "external_tax_from_receipt", "items_as_tax_excluded"
        :line_total_as_net
      when "mixed_by_tax_rate_group"
        :mixed_by_tax_rate_group
      else
        :line_total_as_recorded
      end
    end

    def deltas_for(candidate)
      {
        total: delta_from_score_breakdown(candidate, :receipt_total_delta, 100),
        subtotal: delta_from_score_breakdown(candidate, :receipt_subtotal_delta, 30),
        tax: delta_from_score_breakdown(candidate, :receipt_tax_delta, 60),
        tax_details: 0,
        item_line_total: 0,
        discount: 0,
        basis_relation: 0
      }
    end

    def delta_from_score_breakdown(candidate, key, weight)
      value = candidate.score_breakdown[key]
      return 0 if value.nil?

      value.to_i / weight
    end

    def profile_score_for(candidate)
      deltas = deltas_for(candidate)
      profile = profile_for(candidate)
      deltas[:total].to_i * 100 +
        deltas[:tax].to_i * 80 +
        deltas[:subtotal].to_i * 50 +
        deltas[:tax_details].to_i * 80 +
        deltas[:item_line_total].to_i * 40 +
        deltas[:discount].to_i * 40 +
        deltas[:basis_relation].to_i * 100 +
        native_candidate_basis_penalty(candidate) +
        profile_basis_penalty(profile)
    end

    def native_candidate_basis_penalty(candidate)
      return 0 if candidate_profile(candidate)[:item_amount_basis_assignments].present?

      [ candidate.score_breakdown[:basis_penalty].to_i, 0 ].max
    end

    def profile_basis_penalty(profile)
      return 0 unless explicit_external_tax_evidence?

      penalty = 0
      penalty += 10_000 unless profile[:receipt_tax_basis].to_s == "tax_added_to_subtotal"
      penalty += 25 unless profile[:item_amount_basis].to_s == "line_total_as_net"
      penalty
    end

    def profile_sort_key(profile)
      [
        tax_rounding_priority(profile[:tax_rounding_mode]),
        discount_rounding_priority(profile[:discount_rounding_mode]),
        receipt_tax_basis_priority(profile[:receipt_tax_basis]),
        item_amount_basis_priority(profile[:item_amount_basis])
      ]
    end

    def tax_rounding_priority(mode)
      { floor: 0, round: 1, ceil: 2 }.fetch(mode, 3)
    end

    def discount_rounding_priority(mode)
      { round: 0, floor: 1, ceil: 2 }.fetch(mode, 3)
    end

    def receipt_tax_basis_priority(basis)
      if external_tax_preferred?
        basis == :tax_added_to_subtotal ? 0 : 1
      else
        basis == :total_includes_tax ? 0 : 1
      end
    end

    def item_amount_basis_priority(basis)
      if explicit_external_tax_evidence?
        return { line_total_as_net: 0, line_total_as_recorded: 1, mixed_by_tax_rate_group: 2 }.fetch(basis, 3)
      end

      if mixed_item_amount_basis_suspected?
        return { mixed_by_tax_rate_group: 0, line_total_as_recorded: 1, line_total_as_net: 2 }.fetch(basis, 3)
      end

      { line_total_as_recorded: 0, line_total_as_net: 1, mixed_by_tax_rate_group: 2 }.fetch(basis, 3)
    end

    def profile_warnings
      warnings = []
      warnings << :calculation_profile_uncertain if calculation_profile_uncertain?
      warnings << :price_tax_inclusion_uncertain if price_tax_inclusion_uncertain?
      warnings
    end

    def calculation_profile_uncertain?
      best = profile_candidates.first
      return false unless best
      return false if best[:score].to_i.zero?

      profile_candidates.any? do |candidate|
        next false unless candidate[:score].to_i == best[:score].to_i

        basis_changed?(best[:profile], candidate[:profile])
      end
    end

    def price_tax_inclusion_uncertain?
      best = profile_candidates.first
      return same_rate_mixed_assignment_warning? if best&.[](:score).to_i.zero?

      same_rate_mixed_assignment_warning? || mixed_candidate_ranked_high? || tax_included_tax_excluded_close?
    end

    def mixed_candidate_ranked_high?
      best_score = profile_candidates.first&.[](:score).to_i

      profile_candidates.any? do |candidate|
        next false if candidate[:score].to_i - best_score > 100

        candidate.dig(:profile, :item_amount_basis) == :mixed_by_tax_rate_group
      end
    end

    def tax_included_tax_excluded_close?
      included_score = best_score_for_item_amount_basis(:line_total_as_recorded)
      excluded_score = best_score_for_item_amount_basis(:line_total_as_net)
      return false if included_score.nil? || excluded_score.nil?

      (included_score - excluded_score).abs <= 100
    end

    def best_score_for_item_amount_basis(item_amount_basis)
      profile_candidates
        .select { |candidate| candidate.dig(:profile, :item_amount_basis) == item_amount_basis }
        .map { |candidate| candidate[:score].to_i }
        .min
    end

    def same_rate_mixed_assignment_warning?
      groups = tax_details_by_rate(complete_tax_details)
      return false unless groups.one?

      rate, amounts = groups.first
      return false unless positive_item_tax_rates == [ rate ]

      group_total = items.sum do |item|
        normalize_rate(fetch_value(item, :tax_rate)) == rate ? item_line_total(item) : 0
      end
      printed_gross = amounts[:net_amount] + amounts[:amount]

      amounts[:net_amount] < group_total && group_total < printed_gross
    end

    def basis_changed?(left, right)
      left[:item_amount_basis] != right[:item_amount_basis] || left[:receipt_tax_basis] != right[:receipt_tax_basis]
    end

    def same_rate_item_amount_basis_assignments_for(candidate)
      return nil unless candidate.basis.to_s == "mixed_by_tax_rate_group"
      return nil unless positive_item_tax_rates.one?
      return nil unless tax_details_by_rate(complete_tax_details).one?

      assignments = Array(candidate.evidence).filter_map do |entry|
        next unless entry.respond_to?(:[])
        next unless entry[:source].to_s == "receipt_items"
        basis = entry[:basis].to_s.to_sym
        next unless %i[tax_included tax_excluded].include?(basis)

        {
          assignment_scope: :item,
          item_indices: [ entry[:index].to_i ],
          tax_rate: normalize_rate(entry[:rate]),
          basis: basis,
          net_amount: to_i(entry[:net_amount]),
          tax_amount: to_i(entry[:tax_amount]),
          gross_amount: to_i(entry[:gross_amount])
        }
      end
      return nil unless assignments.any? { |entry| entry[:basis] == :tax_included } &&
        assignments.any? { |entry| entry[:basis] == :tax_excluded }

      assignments
    end

    def external_tax_preferred?
      tax_detail_subtotal.positive? &&
        tax_detail_total.positive? &&
        source_item_total == tax_detail_subtotal &&
        amount_or_nil(fetch_value(receipt, :total_amount)) == tax_detail_subtotal + tax_detail_total
    end

    def explicit_external_tax_evidence?
      tax_details.any? do |tax_detail|
        fetch_value(tax_detail, :description).to_s.match?(/外税|税別|消費税別|別途消費税|exclusive|sales\s*tax/i)
      end
    end

    def mixed_item_amount_basis_suspected?
      return false unless source_item_total.positive?
      return true if tax_detail_subtotal.positive? && tax_detail_subtotal + tax_detail_total < source_item_total

      rates = items.map { |item| normalize_rate(fetch_value(item, :tax_rate)) }.uniq
      rates.include?(BigDecimal("0")) && rates.any?(&:positive?)
    end

    def source_item_total
      @source_item_total ||= items.sum { |item| item_line_total(item) }
    end

    def tax_detail_subtotal
      @tax_detail_subtotal ||= complete_tax_details.sum { |tax_detail| to_i(fetch_value(tax_detail, :net_amount)) }
    end

    def tax_detail_total
      @tax_detail_total ||= complete_tax_details.sum { |tax_detail| to_i(fetch_value(tax_detail, :amount)) }
    end

    def complete_tax_details
      @complete_tax_details ||= tax_details.select do |tax_detail|
        normalize_rate(fetch_value(tax_detail, :rate)).positive? &&
          present?(fetch_value(tax_detail, :net_amount)) &&
          present?(fetch_value(tax_detail, :amount))
      end
    end

    def tax_details_by_rate(details)
      details.each_with_object({}) do |tax_detail, groups|
        rate = normalize_rate(fetch_value(tax_detail, :rate))
        next if rate <= 0

        groups[rate] ||= { amount: 0, net_amount: 0 }
        groups[rate][:amount] += to_i(fetch_value(tax_detail, :amount))
        groups[rate][:net_amount] += to_i(fetch_value(tax_detail, :net_amount))
      end
    end

    def positive_item_tax_rates
      items.filter_map do |item|
        rate = normalize_rate(fetch_value(item, :tax_rate))
        rate if rate.positive?
      end.uniq
    end

    def item_line_total(item)
      line_total = fetch_value(item, :line_total)
      return to_i(line_total) if present?(line_total)

      original_line_total = to_i(fetch_value(item, :original_line_total))
      discount_amount = to_i(fetch_value(item, :discount_amount))
      return [ original_line_total - discount_amount, 0 ].max if original_line_total.positive?

      0
    end

    def fetch_value(object, key)
      if object.respond_to?(:key?)
        return object[key] if object.key?(key)
        object[key.to_s] if object.key?(key.to_s)
      elsif object.respond_to?(key)
        object.public_send(key)
      end
    end

    def normalize_rate(value)
      return BigDecimal("0") unless present?(value)

      rate = BigDecimal(value.to_s.delete("%"))
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError
      BigDecimal("0")
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
  end
end
