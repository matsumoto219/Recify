# frozen_string_literal: true

module Amounts
  class ReviewPolicy
    REVIEW_REQUIRED_WARNINGS = %i[
      price_tax_inclusion_uncertain
      competing_exact_basis_candidate
      mixed_basis_search_truncated
      payment_amount_mismatch
    ].freeze
    PURCHASE_ADJUSTMENT_TAX_ALLOCATION_REVIEW_REASON = :purchase_adjustment_tax_allocation_uncertain

    def initialize(candidate:, existing_inconsistencies:)
      @candidate = candidate
      @existing_inconsistencies = Array(existing_inconsistencies).map(&:to_sym)
    end

    def call
      {
        inconsistencies: inconsistencies,
        review_reasons: review_reasons,
        needs_review: needs_review?
      }
    end

    private

    attr_reader :candidate, :existing_inconsistencies

    def inconsistencies
      (existing_inconsistencies + candidate.warnings + candidate.hard_reject_reasons).uniq
    end

    def review_reasons
      (
        Amounts::MismatchSeverity.blocking(inconsistencies) +
          review_required_warnings
      ).uniq.map(&:to_s)
    end

    def needs_review?
      Amounts::MismatchSeverity.needs_review?(inconsistencies) || review_reasons.present?
    end

    def review_required_warnings
      warnings = inconsistencies & REVIEW_REQUIRED_WARNINGS
      warnings |= incomplete_tax_details_receipt_tax_review_warnings
      warnings |= purchase_adjustment_tax_allocation_review_warnings
      return warnings unless tax_detail_net_price_tax_warning_only?

      warnings - [ :price_tax_inclusion_uncertain ]
    end

    def purchase_adjustment_tax_allocation_review_warnings
      return [] unless candidate.warnings.include?(:adjustment_tax_rate_missing)
      return [] unless tax_rate_missing_purchase_adjustment?
      return [] unless purchase_adjustment_tax_allocation_uncertain?

      [ PURCHASE_ADJUSTMENT_TAX_ALLOCATION_REVIEW_REASON ]
    end

    def incomplete_tax_details_receipt_tax_review_warnings
      return [] unless candidate.basis == "incomplete_tax_details_receipt_tax"

      candidate.warnings & [ :tax_detail_incomplete ]
    end

    def tax_detail_net_price_tax_warning_only?
      return false if inconsistencies.include?(:competing_exact_basis_candidate)

      candidate.basis == "printed_tax_details_net" &&
        candidate.hard_reject_reasons.blank? &&
        candidate.warnings.map(&:to_sym) == [ :price_tax_inclusion_uncertain ] &&
        tax_detail_amounts_match_candidate? &&
        receipt_total_delta.zero?
    end

    def tax_detail_amounts_match_candidate?
      tax_details = Array(candidate.tax_details)
      return false if tax_details.blank?

      tax_details.all? { |tax_detail| tax_detail_complete?(tax_detail) } &&
        tax_details.sum { |tax_detail| to_i(fetch_value(tax_detail, :net_amount)) } == candidate.subtotal.to_i &&
        tax_details.sum { |tax_detail| to_i(fetch_value(tax_detail, :amount)) } == candidate.tax.to_i &&
        candidate.subtotal.to_i + candidate.tax.to_i == candidate.purchase_total.to_i
    end

    def tax_detail_complete?(tax_detail)
      fetch_value(tax_detail, :rate).present? &&
        fetch_value(tax_detail, :net_amount).present? &&
        fetch_value(tax_detail, :amount).present?
    end

    def receipt_total_delta
      to_i(fetch_value(candidate.score_breakdown, :receipt_total_delta))
    end

    def tax_rate_missing_purchase_adjustment?
      receipt_adjustment_evidence.any? do |evidence|
        fetch_value(evidence, :effect).to_s == "purchase_adjustment" &&
          to_i(fetch_value(evidence, :amount)).positive? &&
          tax_rate_missing?(fetch_value(evidence, :tax_rate))
      end
    end

    def purchase_adjustment_tax_allocation_uncertain?
      candidate_positive_tax_rates.many? ||
        taxable_and_non_taxable_groups? ||
        mixed_basis_candidate? ||
        printed_tax_detail_allocation_uncertain?
    end

    def taxable_and_non_taxable_groups?
      candidate_positive_tax_rates.one? && candidate_zero_tax_rate_group?
    end

    def candidate_positive_tax_rates
      Array(candidate.tax_rate_groups).filter_map do |group|
        rate = fetch_value(group, :rate)
        rate = BigDecimal(rate.to_s)
        rate if rate.positive?
      rescue ArgumentError
        nil
      end.uniq
    end

    def candidate_zero_tax_rate_group?
      Array(candidate.tax_rate_groups).any? do |group|
        rate = fetch_value(group, :rate)
        rate = BigDecimal(rate.to_s)
        rate.zero? && (
          to_i(fetch_value(group, :gross)).positive? ||
            to_i(fetch_value(group, :net)).positive?
        )
      rescue ArgumentError
        false
      end
    end

    def printed_tax_detail_allocation_uncertain?
      return false unless printed_tax_detail_evidence?

      candidate_positive_tax_rates.blank?
    end

    def printed_tax_detail_evidence?
      candidate.basis.to_s.start_with?("printed_tax_details", "external_tax_from_receipt") ||
        Array(candidate.evidence).any? { |evidence| fetch_value(evidence, :source).to_s == "receipt_tax_detail" }
    end

    def mixed_basis_candidate?
      candidate.basis.to_s == "mixed_by_tax_rate_group" ||
        fetch_value(candidate.calculation_profile, :item_amount_basis).to_s == "mixed_by_tax_rate_group"
    end

    def receipt_adjustment_evidence
      Array(candidate.evidence).select do |evidence|
        fetch_value(evidence, :source).to_s == "receipt_adjustment"
      end
    end

    def tax_rate_missing?(value)
      return true if value.nil? || value == ""

      BigDecimal(value.to_s).zero?
    rescue ArgumentError
      true
    end

    def fetch_value(hash, key)
      return nil unless hash.respond_to?(:[])

      hash[key] || hash[key.to_s]
    end

    def to_i(value)
      value.respond_to?(:to_i) ? value.to_i : 0
    end
  end
end
