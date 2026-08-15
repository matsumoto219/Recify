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
          rate = projection_tax_rate_for(item)
          return nil if rate.nil?
          group = groups[rate]

          amounts = item_amount_projection(
            item,
            line_total: line_total,
            rate: rate,
            fallback_basis: item_basis,
            rounding_mode: rounding_mode
          )
          group[:item_amounts] << amounts
          computed_items[index] = item_with_line_total(
            item,
            amounts[:gross_amount],
            normalize_price: normalize_price_for_tax_basis?(item, amounts[:basis])
          )
        end

        apply_purchase_adjustments_to_groups!(groups, item_basis: item_basis, rounding_mode: rounding_mode)
        tax_rate_groups = build_tax_rate_groups(groups, rounding_mode, rounding_scope)
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
          calculation_profile: item_candidate_calculation_profile(line_total_source, item_basis),
          source: :amount_engine
        )
      end

      def build_tax_rate_groups(groups, rounding_mode, rounding_scope)
        groups.values.map do |group|
          rate = group[:rate]
          projection = grouped_item_amount_projection(
            group[:item_amounts],
            rate: rate,
            rounding_mode: rounding_mode,
            rounding_scope: rounding_scope
          )
          {
            rate: rate,
            gross: projection[:gross_amount],
            net: projection[:net_amount],
            tax: projection[:tax_amount]
          }
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
        return nil if item[:pricing_source_kind].present?
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

      def item_candidate_calculation_profile(line_total_source, item_basis)
        source = item_candidate_line_total_source(line_total_source)
        item_projection_calculation_profile(
          fallback_basis: item_basis,
          attributes: { line_total_source: source }
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
            {
              basis: :tax_excluded,
              gross_amount: amount + tax,
              net_amount: amount,
              tax_amount: tax
            }
          else
            tax = rate.positive? ? signed_tax_from_gross(amount, rate, rounding_mode) : 0
            {
              basis: item_basis,
              gross_amount: amount,
              net_amount: amount - tax,
              tax_amount: tax
            }
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
