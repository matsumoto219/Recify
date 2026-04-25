# frozen_string_literal: true

module Amounts
  class ResultTemplate
    def self.build(computed:, resolved:, inconsistencies:, tax_details: [], mismatch_codes: [], mismatch_messages: [])
      {
        computed: computed,
        resolved: resolved,
        tax_details: tax_details,
        inconsistencies: inconsistencies,
        mismatch_codes: mismatch_codes,
        mismatch_messages: mismatch_messages,
        needs_review: inconsistencies.any?
      }
    end
  end
end
