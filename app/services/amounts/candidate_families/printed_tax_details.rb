# frozen_string_literal: true

module Amounts
  module CandidateFamilies
    class PrintedTaxDetails < Base
      def call
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

      private

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
          evidence: final_detected_tax_details.map { |detail| detail[:evidence] } + adjustment_evidence + payment_evidence(payment) + [
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
          next unless detail[:net_amount].to_i.positive?
          next unless detail[:amount].to_i.positive? || final_zero_tax_detail?(detail)

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
          evidence: detected_tax_details.map { |detail| detail[:evidence] } + payment_evidence(payment),
          computed_items: items,
          calculation_profile: calculation_profile(
            receipt_tax_basis: :tax_added_to_subtotal,
            item_amount_basis: :line_total_as_net,
            tax_detail_amount_basis: :net
          ),
          source: :amount_engine
        )
      end

      def final_zero_tax_detail?(detail)
        detail[:amount].to_i.zero? &&
          %i[gross net].include?(detail[:basis]) &&
          detail[:target_gross_amount].to_i.positive?
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

      def tax_detail_amounts_for(detail, amount_basis)
        basis = amount_basis == :detected ? detail[:basis] : amount_basis
        case basis
        when :gross
          tax = detail[:target_tax_amount].to_i
          gross = detail[:printed_amount].to_i
          {
            gross: gross,
            net: [ gross - tax, 0 ].max,
            tax: tax
          }
        else
          net = detail[:printed_amount].to_i
          tax = detail[:target_tax_amount].to_i
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
    end
  end
end
