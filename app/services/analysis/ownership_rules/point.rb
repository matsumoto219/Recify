module Analysis
  module OwnershipRules
    class Point
      class << self
        def call(context)
          return unless context.point_text?
          return item_decision if context.item_owned? && !context.point_usage_text?

          if context.informational_point_text?
            return OwnershipRules.decision(
              owner: :informational,
              fact_type: :info,
              effect_scope: :none,
              kind: nil,
              sign: nil,
              action: :reject_false_positive,
              reason: :point_informational
            )
          end
          return review_decision unless context.point_usage_text?

          OwnershipRules.decision(
            owner: :receipt_adjustment,
            fact_type: :payment_adjustment,
            effect_scope: :final_payment_total,
            kind: "point_usage",
            sign: "discount",
            action: :persist
          )
        end

        private

        def item_decision
          OwnershipRules.decision(
            owner: :item,
            fact_type: :line_item,
            effect_scope: :purchase_total,
            kind: nil,
            sign: nil,
            action: :reject_false_positive,
            reason: :item_owned
          )
        end

        def review_decision
          OwnershipRules.decision(
            owner: :review_only,
            fact_type: :unknown_adjustment,
            effect_scope: :none,
            kind: "point_usage",
            sign: "discount",
            action: :review_only,
            review_required: true,
            reason: :point_usage_ownership_uncertain
          )
        end
      end
    end
  end
end
