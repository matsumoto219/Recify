# frozen_string_literal: true

module Amounts
  module CandidateFamilies
    class ReceiptInput < Base
      def call
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
          evidence: payment_evidence(payment) + [ {
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

      private

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
    end
  end
end
