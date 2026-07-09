module Analysis
  module OwnershipRules
    class Payment
      class << self
        def call(context)
          if context.voucher_text?
            return item_decision if context.item_owned?

            return voucher_decision
          end
          return if context.point_usage_text? || context.cashless_reward_text?
          return unless context.payment_owned?

          OwnershipRules.decision(
            owner: :payment,
            fact_type: :payment,
            effect_scope: :payment_reconciliation,
            kind: nil,
            sign: nil,
            action: :reject_false_positive,
            reason: :payment_owned
          )
        end

        private

        def voucher_decision
          OwnershipRules.decision(
            owner: :payment,
            fact_type: :payment,
            effect_scope: :payment_reconciliation,
            kind: nil,
            sign: nil,
            action: :convert_owner,
            reason: :voucher_payment
          )
        end

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
      end
    end
  end
end
