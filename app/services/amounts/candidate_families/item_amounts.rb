# frozen_string_literal: true

module Amounts
  module CandidateFamilies
    class ItemAmounts < Base
      def call
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

      private

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
          evidence: adjustment_evidence + payment_evidence(payment) + [
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

      def item_candidate_line_total_source(line_total_source)
        return nil if line_total_source == :line_total

        line_total_source
      end

      def item_candidate_calculation_profile(line_total_source)
        source = item_candidate_line_total_source(line_total_source)
        return calculation_profile unless source

        calculation_profile(line_total_source: source)
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

      def empty_groups
        Hash.new do |hash, rate|
          hash[rate] = { rate: rate, item_amounts: [] }
        end
      end
    end
  end
end
