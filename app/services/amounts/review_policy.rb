# frozen_string_literal: true

module Amounts
  class ReviewPolicy
    REVIEW_REQUIRED_WARNINGS = %i[
      price_tax_inclusion_uncertain
      payment_amount_mismatch
    ].freeze

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
      (candidate.warnings & REVIEW_REQUIRED_WARNINGS).map(&:to_s)
    end

    def needs_review?
      Amounts::MismatchSeverity.needs_review?(inconsistencies) || review_reasons.present?
    end
  end
end
