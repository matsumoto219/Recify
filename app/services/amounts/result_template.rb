# frozen_string_literal: true

module Amounts
  class ResultTemplate
    def self.build(computed:, resolved:, inconsistencies:)
      {
        computed: computed,
        resolved: resolved,
        inconsistencies: inconsistencies,
        needs_review: inconsistencies.any?
      }
    end
  end
end
