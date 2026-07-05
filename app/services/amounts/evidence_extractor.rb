# frozen_string_literal: true

module Amounts
  class EvidenceExtractor
    class << self
      def payment_evidence(payment, suppress_positive_overpayment:)
        evidence = Array(payment[:evidence])
        return evidence unless suppress_positive_overpayment

        evidence.map do |entry|
          next entry unless fetch_value(entry, :source).to_s == "receipt_payments"

          entry.merge(
            payment_amount_mismatch_suppressed: true,
            suppressed_reason: "tendered_like_overpayment"
          )
        end
      end

      def adjustment_evidence(classified_adjustments)
        Array(classified_adjustments).map { |entry| entry[:classification][:evidence] }
      end

      def incomplete_tax_detail_evidence(incomplete_source_tax_details)
        Array(incomplete_source_tax_details).map.with_index do |detail, index|
          {
            source: "receipt_tax_detail",
            index: index,
            basis: :tax_only,
            description: detail[:description],
            amount: detail[:amount]
          }
        end
      end

      private

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
end
