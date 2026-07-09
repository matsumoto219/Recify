module Analysis
  module OwnershipRules
    class BagFee
      class << self
        def call(context)
          return unless context.kind == "bag_fee" || context.bag_fee_text? || context.bag_item_text?
          if context.kind != "bag_fee" && (context.coupon_text? || context.receipt_discount_text? || context.cashless_reward_text?)
            return
          end

          return item_decision if context.bag_item_text? || context.item_owned? && !context.bag_fee_text?
          return review_decision unless context.bag_fee_text? && context.sign == "surcharge"

          OwnershipRules.decision(
            owner: :receipt_adjustment,
            fact_type: :purchase_adjustment,
            effect_scope: :purchase_total,
            kind: "bag_fee",
            sign: "surcharge",
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
            reason: :bag_item_owned
          )
        end

        def review_decision
          OwnershipRules.decision(
            owner: :review_only,
            fact_type: :unknown_adjustment,
            effect_scope: :none,
            kind: "bag_fee",
            sign: nil,
            action: :review_only,
            review_required: true,
            reason: :bag_fee_ownership_uncertain
          )
        end
      end
    end
  end
end
