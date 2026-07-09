module Analysis
  module OwnershipRules
    class ReturnRefund
      class << self
        def call(context)
          return unless context.kind == "return_refund" || context.return_refund_text?

          OwnershipRules.decision(
            owner: :receipt_adjustment,
            fact_type: :purchase_adjustment,
            effect_scope: :purchase_total,
            kind: "return_refund",
            sign: "discount",
            action: :persist
          )
        end
      end
    end
  end
end
