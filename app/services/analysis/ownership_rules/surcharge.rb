module Analysis
  module OwnershipRules
    class Surcharge
      class << self
        def call(context)
          kind = context.inferred_surcharge_kind
          return if kind.blank? || kind == "bag_fee"
          return review_decision(kind) unless context.sign == "surcharge" && context.explicit_surcharge_text?(kind)

          OwnershipRules.decision(
            owner: :receipt_adjustment,
            fact_type: :purchase_adjustment,
            effect_scope: :purchase_total,
            kind: kind,
            sign: "surcharge",
            action: :persist
          )
        end

        private

        def review_decision(kind)
          OwnershipRules.decision(
            owner: :review_only,
            fact_type: :unknown_adjustment,
            effect_scope: :none,
            kind: kind,
            sign: nil,
            action: :review_only,
            review_required: true,
            reason: :surcharge_ownership_uncertain
          )
        end
      end
    end
  end
end
