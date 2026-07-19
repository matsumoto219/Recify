# frozen_string_literal: true

module Amounts
  class ReviewPolicy
    REVIEW_REQUIRED_WARNINGS = %i[
      price_tax_inclusion_uncertain
      competing_exact_basis_candidate
      mixed_basis_search_truncated
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
      return [] unless review_facts.tax_rate_missing_purchase_adjustment?
      return [] unless review_facts.purchase_adjustment_tax_allocation_uncertain?

      [ PURCHASE_ADJUSTMENT_TAX_ALLOCATION_REVIEW_REASON ]
    end

    def incomplete_tax_details_receipt_tax_review_warnings
      return [] unless candidate.basis == "incomplete_tax_details_receipt_tax"

      candidate.warnings & [ :tax_detail_incomplete ]
    end

    def tax_detail_net_price_tax_warning_only?
      review_facts.tax_detail_net_price_tax_warning_only?(inconsistencies: inconsistencies)
    end

    def review_facts
      @review_facts ||= Amounts::ReviewFacts.new(candidate)
    end
  end
end
