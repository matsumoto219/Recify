module Analysis
  class OwnershipConflictResolver
    ADJUSTMENT_UNCERTAIN_REVIEW_REASON = "adjustment_uncertain"
    INTERNAL_SOURCE_KEYS = %i[
      source_provider
      source_field_path
      field_path
      source_span_start
      source_span_end
      span_start
      span_end
      source_index
      amount_source
      transaction_context
    ].freeze

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(facts:, review_reasons:, profile:)
      @facts = Array(facts)
      @review_reasons = Array(review_reasons).map(&:to_s)
      @profile = profile
      @diagnostics = []
    end

    def call
      add_review_only_reasons!
      convert_payment_owner_adjustments!
      resolve_cross_owner_conflicts!
      deduplicate_same_source_facts!
      aggregate_voucher_payments!

      OwnershipResult.new(
        items: attributes_for(:item),
        adjustments: attributes_for(:adjustment),
        payments: attributes_for(:payment),
        tax_details: attributes_for(:tax_detail),
        facts: facts,
        review_reasons: review_reasons.uniq,
        diagnostics: diagnostics
      )
    end

    private

    attr_reader :facts, :review_reasons, :profile, :diagnostics

    def add_review_only_reasons!
      return unless facts.any? { |fact| fact.origin == :adjustment && fact.action == :review_only }

      review_reasons << ADJUSTMENT_UNCERTAIN_REVIEW_REASON
    end

    def convert_payment_owner_adjustments!
      convertible_adjustments.each do |adjustment_fact|
        matching_payment = active_facts(:payment).find { |payment_fact| same_source_token?(adjustment_fact, payment_fact) }
        if matching_payment
          mark_dropped!(adjustment_fact, :drop_duplicate, :voucher_payment_duplicate)
          next
        end

        facts << converted_payment_fact(adjustment_fact)
        adjustment_fact.action = :convert_owner
        diagnostics << diagnostic(:owner_converted, from: :adjustment, to: :payment)
      end
    end

    def convertible_adjustments
      facts.select do |fact|
        fact.origin == :adjustment && fact.owner == :payment && fact.action == :convert_owner
      end
    end

    def converted_payment_fact(adjustment_fact)
      attributes = adjustment_fact.attributes.with_indifferent_access
      payment_attributes = {
        method: voucher_payment_method(attributes),
        amount: adjustment_fact.amount.to_i
      }

      OwnershipFact.new(
        owner: :payment,
        fact_type: :payment,
        effect_scope: :payment_reconciliation,
        amount: adjustment_fact.amount,
        source_refs: adjustment_fact.source_refs,
        action: :persist,
        review_reasons: [],
        diagnostics: [ :converted_from_adjustment ],
        attributes: payment_attributes.with_indifferent_access,
        origin: :payment,
        tax_rate_source: :not_applicable
      )
    end

    def voucher_payment_method(attributes)
      source = attributes[:source_text].presence || attributes[:label].presence || attributes[:method].presence
      label = source.to_s.unicode_normalize(:nfkc).sub(
        /\s*[▲△\-−]?\s*[¥￥$€£]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:円)?\s*\z/,
        ""
      ).strip

      label.presence || profile.voucher_label
    end

    def resolve_cross_owner_conflicts!
      tax_facts = active_facts(:tax_detail)
      payment_facts = active_facts(:payment)
      adjustment_facts = active_facts(:adjustment)

      tax_facts.each do |tax_fact|
        active_facts.each do |fact|
          next if fact.equal?(tax_fact) || fact.origin == :tax_detail
          next unless same_source_token?(tax_fact, fact)

          mark_dropped!(fact, :reject_false_positive, :tax_detail_owner_wins)
        end
      end

      payment_facts.each do |payment_fact|
        active_facts(:item).each do |item_fact|
          next unless same_source_token?(payment_fact, item_fact)

          mark_dropped!(item_fact, :reject_false_positive, :payment_owner_wins)
        end
      end

      adjustment_facts.each do |adjustment_fact|
        resolve_adjustment_item_conflict!(adjustment_fact)
        resolve_adjustment_payment_conflict!(adjustment_fact)
      end
    end

    def resolve_adjustment_item_conflict!(adjustment_fact)
      active_facts(:item).each do |item_fact|
        next unless same_source_token?(adjustment_fact, item_fact)

        if adjustment_fact.owner == :receipt_adjustment && purchase_adjustment_owner?(adjustment_fact)
          mark_dropped!(item_fact, :convert_owner, :adjustment_owner_wins)
        else
          mark_dropped!(adjustment_fact, :reject_false_positive, :item_owner_wins)
        end
      end
    end

    def resolve_adjustment_payment_conflict!(adjustment_fact)
      active_facts(:payment).each do |payment_fact|
        next unless same_source_token?(adjustment_fact, payment_fact)

        if adjustment_fact.fact_type == :payment_adjustment
          mark_dropped!(payment_fact, :convert_owner, :payment_adjustment_owner_wins)
        else
          mark_dropped!(adjustment_fact, :reject_false_positive, :payment_owner_wins)
        end
      end
    end

    def purchase_adjustment_owner?(fact)
      fact.fact_type == :purchase_adjustment &&
        (ReceiptAdjustment::SURCHARGE_KINDS + [ "return_refund" ]).include?(fact.kind.to_s)
    end

    def deduplicate_same_source_facts!
      active_facts.group_by { |fact| primary_source_identity(fact) }.each_value do |group|
        next if group.one?

        group.group_by(&:origin).each_value do |same_origin_facts|
          next if same_origin_facts.one?

          preferred = preferred_fact(same_origin_facts)
          same_origin_facts.each do |fact|
            next if fact.equal?(preferred)

            mark_dropped!(fact, :drop_duplicate, :same_source_duplicate)
          end
        end
      end
    end

    def aggregate_voucher_payments!
      voucher_payment_facts.group_by { |fact| normalized_voucher_method(fact) }.each_value do |group|
        next if group.one?

        representative = group.first
        total = group.sum { |fact| fact.amount.to_i }
        representative.amount = total
        representative.attributes = representative.attributes.to_h.with_indifferent_access.merge(
          method: voucher_payment_method(representative.attributes.with_indifferent_access),
          amount: total
        )
        representative.source_refs = group.flat_map { |fact| Array(fact.source_refs) }.uniq(&:identity)
        group.drop(1).each { |fact| mark_dropped!(fact, :aggregate, :voucher_payments_aggregated) }
      end
    end

    def voucher_payment_facts
      active_facts(:payment).select do |fact|
        fact.attributes.with_indifferent_access[:method].to_s.match?(profile.analysis_voucher_payment_pattern)
      end
    end

    def normalized_voucher_method(fact)
      voucher_payment_method(fact.attributes.with_indifferent_access).unicode_normalize(:nfkc).downcase.gsub(/\s+/, "")
    end

    def preferred_fact(group)
      group.max_by do |fact|
        attributes = fact.attributes.with_indifferent_access
        [ attributes[:source].to_s == "ai" ? 1 : 0, attributes[:confidence].to_f ]
      end
    end

    def mark_dropped!(fact, action, reason)
      return unless fact.action == :persist || fact.action == :convert_owner

      fact.action = action
      fact.diagnostics = Array(fact.diagnostics) | [ reason ]
      diagnostics << diagnostic(reason, origin: fact.origin)
    end

    def same_source_token?(left, right)
      left_identities = strong_source_identities(left)
      return false if left_identities.empty?

      (left_identities & strong_source_identities(right)).any?
    end

    def primary_source_identity(fact)
      strong_source_identities(fact).first || [ :weak, fact.object_id ]
    end

    def strong_source_identities(fact)
      Array(fact.source_refs).filter_map(&:strong_identity)
    end

    def active_facts(origin = nil)
      facts.select do |fact|
        fact.action == :persist && (origin.nil? || fact.origin == origin)
      end
    end

    def attributes_for(origin)
      active_facts(origin).map do |fact|
        sanitize_attributes(fact.attributes, origin)
      end
    end

    def sanitize_attributes(value, origin)
      attributes = value.to_h.with_indifferent_access.except(*INTERNAL_SOURCE_KEYS)
      return attributes.slice(:method, :amount).to_h.symbolize_keys if origin == :payment

      attributes.to_h.symbolize_keys
    end

    def diagnostic(code, details = {})
      { code: code, **details }
    end
  end
end
