module Analysis
  module OwnershipRules
    Decision = Struct.new(
      :owner,
      :fact_type,
      :effect_scope,
      :kind,
      :sign,
      :action,
      :review_required,
      :reason,
      keyword_init: true
    ) do
      def persist?
        action == :persist
      end

      def accepted_proposal?
        persist? || action == :convert_owner
      end
    end

    class << self
      def classify(...)
        context = Context.new(...)
        matching_decision(context) || default_decision(context)
      end

      def decision(owner:, fact_type:, effect_scope:, kind:, sign:, action:, review_required: false, reason: nil)
        Decision.new(
          owner: owner,
          fact_type: fact_type,
          effect_scope: effect_scope,
          kind: kind,
          sign: sign,
          action: action,
          review_required: review_required,
          reason: reason
        )
      end

      private

      def matching_decision(context)
        rules.each do |rule|
          decision = rule.call(context)
          return decision if decision
        end

        nil
      end

      def rules
        [ TaxDetail, Point, Payment, ReturnRefund, BagFee, Surcharge, Discount ]
      end

      def default_decision(context)
        kind = context.valid_kind? ? context.kind : "other"
        sign = context.valid_sign? ? context.sign : ReceiptAdjustment.default_sign_for(kind)

        decision(
          owner: :receipt_adjustment,
          fact_type: :unknown_adjustment,
          effect_scope: :purchase_total,
          kind: kind,
          sign: sign,
          action: :persist,
          review_required: true,
          reason: :unclassified_adjustment
        )
      end
    end
  end
end
