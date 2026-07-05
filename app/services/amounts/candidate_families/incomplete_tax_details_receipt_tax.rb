# frozen_string_literal: true

module Amounts
  module CandidateFamilies
    class IncompleteTaxDetailsReceiptTax < Base
      def call
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
          evidence: incomplete_tax_detail_evidence + adjustment_evidence + payment_evidence(payment) + [ {
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
    end
  end
end
