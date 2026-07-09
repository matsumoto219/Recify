module Analysis
  module OwnershipRules
    class TaxDetail
      class << self
        def call(context)
          return unless context.tax_detail_owned?

          OwnershipRules.decision(
            owner: :tax_detail,
            fact_type: :tax_summary,
            effect_scope: :tax_allocation,
            kind: nil,
            sign: nil,
            action: :reject_false_positive,
            reason: :tax_detail_owned
          )
        end
      end
    end
  end
end
