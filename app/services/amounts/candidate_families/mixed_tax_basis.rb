# frozen_string_literal: true

module Amounts
  module CandidateFamilies
    class MixedTaxBasis < Base
      def call
        return [] unless final_detected_tax_details.present?

        tax_rounding_modes.map do |rounding_mode|
          mixed_candidate(rounding_mode)
        end.compact
      end

      private

      def mixed_candidate(rounding_mode)
        targets = tax_detail_targets_by_rate
        return nil if targets.blank?

        alternative_result = alternative_rate_mixed_candidate(rounding_mode, targets)
        return alternative_result[:candidate] if alternative_result[:candidate]

        computed_items = Array.new(items.size)
        groups = {}
        warnings = adjustment_warnings.dup
        warnings << :competing_exact_basis_candidate if alternative_result[:status] == :ambiguous
        warnings << :mixed_basis_search_truncated if alternative_result[:status] == :search_limited
        exact = true
        mixed_basis_used = false
        evidence = final_detected_tax_details.map { |detail| detail[:evidence] }
        profile_assignments = []
        purchase_adjustment_groups = purchase_adjustment_groups_by_rate(rounding_mode)

        indexed_items_by_rate.each do |rate, indexed_items|
          if rate.zero?
            gross = indexed_items.sum { |item, _index| item_line_total(item) }
            groups[rate] = { rate: rate, gross: gross, net: gross, tax: 0 }
            indexed_items.each { |item, index| computed_items[index] = item_with_line_total(item, item_line_total(item), tax_rate: BigDecimal("0")) }
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
            warnings << :mixed_basis_search_truncated if assignment[:status] == :search_limited
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
              normalize_price: entry[:basis] == :tax_excluded,
              tax_rate: entry[:rate]
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
        warnings << :price_tax_inclusion_uncertain if mixed_price_tax_inclusion_uncertain?(purchase_total, tax, mixed_basis_used)
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
          evidence: evidence + adjustment_evidence + payment_evidence(payment) + [ { source: "amount_engine", formula: "mixed_by_tax_rate_group", purchase_total: purchase_total } ],
          computed_items: computed_items.map.with_index { |item, index| item || item_with_line_total(items[index], item_line_total(items[index])) },
          calculation_profile: mixed_calculation_profile(profile_assignments),
          source: :amount_engine
        )
      end

      def alternative_rate_mixed_candidate(rounding_mode, targets)
        return { status: :not_applicable } unless tax_excluded_price_conversion_enabled?
        return { status: :not_applicable } unless targets.keys.many?

        purchase_adjustment_groups = purchase_adjustment_groups_by_rate(rounding_mode)
        assignment = item_level_assignment_across_tax_rates_for(targets, purchase_adjustment_groups, rounding_mode)
        return { status: assignment[:status] } unless assignment[:status] == :exact

        groups = targets.transform_values { |target| target.slice(:rate, :gross, :net, :tax) }
        zero_total = assignment[:zero_assignments].sum { |entry| entry[:gross_amount] }
        groups[BigDecimal("0")] = { rate: BigDecimal("0"), gross: zero_total, net: zero_total, tax: 0 } if zero_total.positive?

        computed_items = Array.new(items.size)
        profile_assignments = []
        assignment[:assignments].each do |entry|
          computed_items[entry[:index]] = item_with_line_total(
            items[entry[:index]],
            entry[:gross_amount],
            normalize_price: entry[:basis] == :tax_excluded,
            tax_rate: entry[:rate]
          )
          profile_assignments << {
            tax_rate: entry[:rate],
            basis: entry[:basis],
            net_amount: entry[:net_amount],
            tax_amount: entry[:tax_amount],
            gross_amount: entry[:gross_amount]
          }
        end
        assignment[:zero_assignments].each do |entry|
          computed_items[entry[:index]] = item_with_line_total(items[entry[:index]], entry[:gross_amount], tax_rate: BigDecimal("0"))
        end
        profile_assignments << {
          tax_rate: BigDecimal("0"),
          basis: :non_taxable,
          net_amount: zero_total,
          tax_amount: 0,
          gross_amount: zero_total
        } if zero_total.positive?

        purchase_total = groups.values.sum { |group| group[:gross] } +
          unapplied_purchase_adjustment_total(purchase_adjustment_groups, groups.keys)
        tax = groups.values.sum { |group| group[:tax] }
        warnings = adjustment_warnings.dup
        mixed_basis_used = assignment[:assignments].any? { |entry| entry[:basis] == :tax_excluded }
        warnings << :price_tax_inclusion_uncertain if mixed_price_tax_inclusion_uncertain?(purchase_total, tax, mixed_basis_used)
        payment = payment_reconciliation(purchase_total, payment_adjustment_total)
        warnings += payment_warnings(payment)

        {
          status: :exact,
          candidate: Amounts::Candidate.new(
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
            hard_reject_reasons: [],
            evidence: final_detected_tax_details.map { |detail| detail[:evidence] } +
              assignment[:assignments].map { |entry| entry.slice(:source, :index, :basis, :rate, :net_amount, :tax_amount, :gross_amount) } +
              adjustment_evidence +
              payment_evidence(payment) +
              [ { source: "amount_engine", formula: "mixed_by_tax_rate_group", purchase_total: purchase_total } ],
            computed_items: computed_items.map.with_index { |item, index| item || item_with_line_total(items[index], item_line_total(items[index])) },
            calculation_profile: mixed_calculation_profile(profile_assignments),
            source: :amount_engine
          )
        }
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
        return { status: :search_limited, assignments: [] } if indexed_items.size > Amounts::CandidateGenerator::SAME_RATE_MIXED_MAX_ITEMS

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

          return { status: :search_limited, assignments: [] } if next_states.size > Amounts::CandidateGenerator::SAME_RATE_MIXED_MAX_STATES
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

      def item_level_assignment_across_tax_rates_for(targets, purchase_adjustment_groups, rounding_mode)
        rates = targets.keys.sort
        return { status: :no_exact, assignments: [], zero_assignments: [] } if rates.blank?

        positive_items = []
        zero_assignments = []
        items.each_with_index do |item, index|
          line_total = item_line_total(item)
          if zero_rate_item_for_mixed_assignment?(item)
            zero_assignments << {
              source: "receipt_items",
              index: index,
              rate: BigDecimal("0"),
              basis: :non_taxable,
              net_amount: line_total,
              tax_amount: 0,
              gross_amount: line_total
            }
          elsif line_total.positive?
            positive_items << [ item, index ]
          end
        end

        return { status: :search_limited, assignments: [], zero_assignments: [] } if positive_items.size > Amounts::CandidateGenerator::SAME_RATE_MIXED_MAX_ITEMS

        assignment_targets = rates.to_h do |rate|
          [ rate, target_before_purchase_adjustments(targets.fetch(rate), purchase_adjustment_groups[rate]) ]
        end
        target_key = mixed_assignment_key_for(rates, assignment_targets)
        states = { mixed_assignment_zero_key(rates) => [ [] ] }

        positive_items.each do |item, index|
          candidates = rates.flat_map { |rate| item_level_basis_candidates(item, index, rate, rounding_mode) }
          return { status: :no_exact, assignments: [], zero_assignments: zero_assignments } if candidates.blank?

          next_states = {}
          states.each do |key, paths|
            candidates.each do |candidate|
              next_key = mixed_assignment_next_key(key, candidate, rates)
              next if mixed_assignment_exceeds_target?(next_key, rates, assignment_targets)

              next_states[next_key] ||= []
              paths.each do |path|
                next_states[next_key] << (path + [ candidate ])
                next_states[next_key] = next_states[next_key].first(2)
              end
            end
          end

          return { status: :search_limited, assignments: [], zero_assignments: zero_assignments } if next_states.size > Amounts::CandidateGenerator::SAME_RATE_MIXED_MAX_STATES
          return { status: :no_exact, assignments: [], zero_assignments: zero_assignments } if next_states.blank?

          states = next_states
        end

        matches = states[target_key] || []
        return { status: :ambiguous, assignments: [], zero_assignments: zero_assignments } if matches.many?
        return { status: :no_exact, assignments: [], zero_assignments: zero_assignments } if matches.blank?

        {
          status: :exact,
          assignments: matches.first,
          zero_assignments: zero_assignments
        }
      end

      def zero_rate_item_for_mixed_assignment?(item)
        item = indifferent_hash(item)
        non_taxable_item_text?(item) ||
          item_tax_rate(item).zero?
      end

      def mixed_assignment_zero_key(rates)
        Array.new(rates.size * 3, 0)
      end

      def mixed_assignment_key_for(rates, targets)
        rates.flat_map do |rate|
          target = targets.fetch(rate)
          [ target[:net], target[:tax], target[:gross] ]
        end
      end

      def mixed_assignment_next_key(key, candidate, rates)
        next_key = key.dup
        offset = rates.index(candidate[:rate]) * 3
        next_key[offset] += candidate[:net_amount]
        next_key[offset + 1] += candidate[:tax_amount]
        next_key[offset + 2] += candidate[:gross_amount]
        next_key
      end

      def mixed_assignment_exceeds_target?(key, rates, targets)
        rates.each_with_index.any? do |rate, index|
          target = targets.fetch(rate)
          offset = index * 3
          key[offset] > target[:net] ||
            key[offset + 1] > target[:tax] ||
            key[offset + 2] > target[:gross]
        end
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

      def receipt_total_matches_candidate?(purchase_total)
        total = amount_or_nil(receipt[:total_amount])

        !total.nil? && total == purchase_total.to_i
      end

      def mixed_price_tax_inclusion_uncertain?(purchase_total, tax, mixed_basis_used)
        return false unless mixed_basis_used
        return false if receipt_total_matches_candidate?(purchase_total) && final_tax_detail_target_evidence_complete?

        !receipt_amounts_match_candidate?(purchase_total, tax)
      end

      def final_tax_detail_target_evidence_complete?
        target_rates = tax_detail_targets_by_rate.keys
        return false unless target_rates.many?

        target_rates.all? do |rate|
          final_detected_tax_details.any? do |detail|
            detail[:rate] == rate &&
              detail[:description].to_s.match?(profile.amount_tax_detail_gross_description_pattern)
          end
        end
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

      def tax_detail_targets_by_rate
        final_detected_tax_details.each_with_object({}) do |detail, hash|
          rate = detail[:rate]
          next unless rate.positive?

          hash[rate] ||= { rate: rate, gross: 0, net: 0, tax: 0 }
          hash[rate][:gross] += detail[:target_gross_amount].to_i
          hash[rate][:net] += detail[:target_net_amount].to_i
          hash[rate][:tax] += detail[:target_tax_amount].to_i
        end
      end
    end
  end
end
