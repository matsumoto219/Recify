# frozen_string_literal: true

module Amounts
  class CandidateScorer
    def initialize(receipt:, payments:, tax_details: [])
      @receipt = receipt
      @payments = Array(payments)
      @tax_details = Array(tax_details)
    end

    def call(candidate)
      breakdown = score_breakdown(candidate)
      candidate.with_score(
        score: breakdown.values.sum,
        score_breakdown: breakdown
      )
    end

    private

    attr_reader :receipt, :payments, :tax_details

    def score_breakdown(candidate)
      {
        receipt_total_delta: amount_delta(candidate.purchase_total, :total_amount) * 100,
        receipt_subtotal_delta: amount_delta(candidate.subtotal, :subtotal_amount) * 30,
        receipt_tax_delta: amount_delta(candidate.tax, :tax_amount) * 60,
        payment_delta: payment_delta(candidate) * 120,
        hard_reject_penalty: candidate.rejected? ? 1_000_000 : 0,
        basis_penalty: basis_penalty(candidate)
      }
    end

    def amount_delta(computed_value, receipt_key)
      printed = Amounts::NumberParser.parse_amount_or_nil(fetch_value(receipt, receipt_key))
      return 0 if printed.nil?

      (computed_value.to_i - printed).abs
    end

    def payment_delta(candidate)
      return 0 if payments.blank? || candidate.payment_amount_sum.nil?

      (candidate.payment_amount_sum.to_i - candidate.final_payment_total.to_i).abs
    end

    def basis_penalty(candidate)
      case candidate.basis.to_s
      when "legacy_resolver"
        5
      when "mixed_by_tax_rate_group"
        external_tax_evidence? ? 15 : 0
      when "external_tax_from_receipt"
        external_tax_evidence? ? 0 : 3
      when "items_as_tax_included", "items_as_tax_excluded"
        10
      else
        25
      end
    end

    def external_tax_evidence?
      return true if tax_details.any? { |detail| fetch_value(detail, :description).to_s.match?(/外税|税別|消費税別|別途消費税|exclusive|sales\s*tax/i) }

      subtotal = Amounts::NumberParser.parse_amount_or_nil(fetch_value(receipt, :subtotal_amount))
      tax = Amounts::NumberParser.parse_amount_or_nil(fetch_value(receipt, :tax_amount))
      total = Amounts::NumberParser.parse_amount_or_nil(fetch_value(receipt, :total_amount))

      subtotal.present? &&
        tax.present? &&
        total.present? &&
        subtotal + tax == total &&
        detected_tax_details.present? &&
        detected_tax_details.all? { |detail| detail[:basis] == :net }
    end

    def detected_tax_details
      @detected_tax_details ||= Amounts::TaxDetailBasisDetector.call(tax_details).select do |detail|
        detail[:rate].positive? && detail[:amount].to_i.positive? && detail[:net_amount].to_i.positive?
      end
    end

    def fetch_value(object, key)
      if object.respond_to?(:key?)
        return object[key] if object.key?(key)
        return object[key.to_s] if object.key?(key.to_s)
      elsif object.respond_to?(key)
        object.public_send(key)
      end
    end
  end
end
