module Analysis
  module OwnershipRules
    class Discount
      class << self
        def call(context)
          return unless applicable?(context)
          return informational_decision if context.post_settlement_promo?
          return item_decision(:item_discount_owned) if context.item_discount_owned?
          return item_decision(:item_owned) if context.item_owned?
          return cashless_decision if context.cashless_reward_text?
          return purchase_decision("coupon") if context.coupon_text?
          return purchase_decision("receipt_discount") if context.receipt_discount_text?

          review_decision(context)
        end

        private

        def applicable?(context)
          %w[coupon receipt_discount].include?(context.kind) ||
            context.coupon_text? ||
            context.receipt_discount_text? ||
            context.cashless_reward_text? ||
            context.post_settlement_promo? ||
            context.item_discount_owned?
        end

        def purchase_decision(kind)
          OwnershipRules.decision(
            owner: :receipt_adjustment,
            fact_type: :purchase_adjustment,
            effect_scope: :purchase_total,
            kind: kind,
            sign: "discount",
            action: :persist
          )
        end

        def cashless_decision
          OwnershipRules.decision(
            owner: :receipt_adjustment,
            fact_type: :payment_adjustment,
            effect_scope: :final_payment_total,
            kind: "receipt_discount",
            sign: "discount",
            action: :persist
          )
        end

        def item_decision(reason)
          OwnershipRules.decision(
            owner: :item,
            fact_type: :line_item,
            effect_scope: :purchase_total,
            kind: nil,
            sign: nil,
            action: :reject_false_positive,
            reason: reason
          )
        end

        def informational_decision
          OwnershipRules.decision(
            owner: :informational,
            fact_type: :info,
            effect_scope: :none,
            kind: nil,
            sign: nil,
            action: :reject_false_positive,
            reason: :post_settlement_promotion
          )
        end

        def review_decision(context)
          OwnershipRules.decision(
            owner: :review_only,
            fact_type: :unknown_adjustment,
            effect_scope: :none,
            kind: context.valid_kind? ? context.kind : "other",
            sign: context.valid_sign? ? context.sign : "discount",
            action: :review_only,
            review_required: true,
            reason: :discount_ownership_uncertain
          )
        end
      end
    end
  end
end
