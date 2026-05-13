# frozen_string_literal: true

module Amounts
  class ResultTemplate
    def self.build(computed:, resolved:, inconsistencies:, tax_details: [], mismatch_codes: [], mismatch_messages: [])
      blocking_inconsistencies = Amounts::MismatchSeverity.blocking(inconsistencies)
      warning_inconsistencies = Amounts::MismatchSeverity.warning(inconsistencies)

      {
        computed: computed,
        resolved: resolved,
        tax_details: tax_details,
        inconsistencies: inconsistencies,
        blocking_inconsistencies: blocking_inconsistencies,
        warning_inconsistencies: warning_inconsistencies,
        warning_reasons: warning_inconsistencies.map(&:to_s),
        mismatch_codes: mismatch_codes,
        blocking_mismatch_codes: mismatch_codes_for(blocking_inconsistencies),
        warning_mismatch_codes: mismatch_codes_for(warning_inconsistencies),
        mismatch_messages: mismatch_messages,
        needs_review: blocking_inconsistencies.any?
      }
    end

    def self.mismatch_codes_for(inconsistencies)
      Array(inconsistencies).filter_map do |inconsistency|
        Amounts::MismatchCodes.code(inconsistency.to_sym)
      end
    end

    private_class_method :mismatch_codes_for
  end
end
