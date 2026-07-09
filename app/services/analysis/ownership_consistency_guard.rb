module Analysis
  class OwnershipConsistencyGuard
    SCHEMA_VERSION = 1
    ADJUSTMENT_REVIEW_REASON = "adjustment_uncertain"
    TAX_ALLOCATION_REVIEW_REASON = "purchase_adjustment_tax_allocation_uncertain"
    CONFLICT_COUNT_KEYS = %i[
      duplicate_source_owner_count
      payment_source_purchase_adjustment_count
      tax_detail_source_effect_count
    ].freeze

    class << self
      def call(params:)
        new(params).call
      end

      def contract_for(ownership_result)
        facts = Array(ownership_result.facts).select { |fact| fact.action == :persist }
        source_groups = source_groups_for(facts)

        {
          schema_version: SCHEMA_VERSION,
          duplicate_source_owner_count: source_groups.count { |_identity, group| group.many? },
          payment_source_purchase_adjustment_count: source_groups.count do |_identity, group|
            group.any? { |fact| fact.origin == :payment } &&
              group.any? { |fact| fact.origin == :adjustment && fact.fact_type == :purchase_adjustment }
          end,
          tax_detail_source_effect_count: source_groups.count do |_identity, group|
            group.any? { |fact| fact.origin == :tax_detail } &&
              group.any? { |fact| %i[adjustment payment].include?(fact.origin) }
          end,
          unknown_purchase_tax_allocation_count: facts.count do |fact|
            fact.origin == :adjustment &&
              fact.fact_type == :purchase_adjustment &&
              fact.tax_rate_source == :unknown &&
              Array(fact.review_reasons).map(&:to_s).include?(TAX_ALLOCATION_REVIEW_REASON)
          end,
          adjustment_review_required_count: facts.count do |fact|
            fact.origin == :adjustment && adjustment_review_required?(fact)
          end
        }
      end

      def review_reason_resolved?(params:, reason:)
        return false unless reason.to_s == ADJUSTMENT_REVIEW_REASON

        contract = contract_from(params)
        return false if contract.blank?

        contract[:adjustment_review_required_count].to_i.zero? &&
          CONFLICT_COUNT_KEYS.all? { |key| contract[key].to_i.zero? }
      end

      def contract_from(params)
        value = params.respond_to?(:[]) ? params[:ownership_contract] || params["ownership_contract"] : nil
        return {}.with_indifferent_access unless value.respond_to?(:to_h)

        value.to_h.with_indifferent_access
      end

      private

      def source_groups_for(facts)
        facts.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |fact, grouped|
          Array(fact.source_refs).filter_map(&:strong_identity).each do |identity|
            grouped[identity] << fact unless grouped[identity].include?(fact)
          end
        end
      end

      def adjustment_review_required?(fact)
        fact.attributes.with_indifferent_access[:needs_review] == true ||
          ReviewReasons.blocking_reasons_for_user(Array(fact.review_reasons)).any?
      end
    end

    def initialize(params)
      @params = params.respond_to?(:deep_dup) ? params.deep_dup : {}
    end

    def call
      contract = self.class.contract_from(params)
      return params if contract.blank?

      reasons = Array(params[:review_reasons]).map(&:to_s)
      reasons << ADJUSTMENT_REVIEW_REASON if conflict_present?(contract)
      if contract[:unknown_purchase_tax_allocation_count].to_i.positive?
        reasons << TAX_ALLOCATION_REVIEW_REASON
      end
      params[:review_reasons] = ReviewReasons.review_reasons_for_user(reasons)
      params
    end

    private

    attr_reader :params

    def conflict_present?(contract)
      CONFLICT_COUNT_KEYS.any? { |key| contract[key].to_i.positive? }
    end
  end
end
