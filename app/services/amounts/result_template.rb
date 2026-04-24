# frozen_string_literal: true

module Amounts
  class ResultTemplate
    def self.build(computed:, resolved:, inconsistencies:, tax_details: [])
      {
        computed: computed,
        resolved: resolved,
        tax_details: tax_details,
        inconsistencies: inconsistencies,
        needs_review: inconsistencies.any?
      }
    end
  end
end
