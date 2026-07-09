module Analysis
  class TaxAllocationResolver
    REVIEW_REASON = "purchase_adjustment_tax_allocation_uncertain"
    INTERNAL_TAX_SOURCE_KEY = :_tax_rate_source

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(ownership_result:, items:, adjustments:, tax_details:, tax_rate_correction: nil)
      @ownership_result = ownership_result
      @items = Array(items).map { |item| normalized_hash(item) }
      @adjustments = Array(adjustments).map { |adjustment| normalized_hash(adjustment) }
      @tax_details = Array(tax_details).map { |tax_detail| normalized_hash(tax_detail) }
      @tax_rate_correction = normalized_hash(tax_rate_correction)
      @review_reasons = Array(ownership_result.review_reasons).map(&:to_s)
    end

    def call
      resolved_adjustments = active_adjustment_facts.zip(adjustments).map do |fact, adjustment|
        resolve_adjustment(fact, adjustment)
      end

      OwnershipResult.new(
        items: ownership_result.items,
        adjustments: resolved_adjustments,
        payments: ownership_result.payments,
        tax_details: ownership_result.tax_details,
        facts: ownership_result.facts,
        review_reasons: review_reasons.uniq,
        diagnostics: ownership_result.diagnostics
      )
    end

    private

    attr_reader :ownership_result, :items, :adjustments, :tax_details, :tax_rate_correction, :review_reasons

    def active_adjustment_facts
      Array(ownership_result.facts).select do |fact|
        fact.origin == :adjustment && fact.action == :persist
      end
    end

    def resolve_adjustment(fact, adjustment)
      if fact.fact_type == :payment_adjustment
        return apply_resolution(fact, adjustment, tax_rate: nil, source: :not_applicable)
      end

      explicit_rate = normalized_rate(adjustment[:tax_rate])
      if explicit_rate
        source = normalize_tax_rate_source(adjustment[INTERNAL_TAX_SOURCE_KEY]) || correction_tax_rate_source || :explicit
        return apply_resolution(fact, adjustment, tax_rate: explicit_rate, source: source)
      end

      inherited_rate = inherited_item_tax_rate(fact)
      return apply_resolution(fact, adjustment, tax_rate: inherited_rate, source: :inherited) if inherited_rate

      matched_rate = matched_tax_detail_rate(fact.amount)
      return apply_resolution(fact, adjustment, tax_rate: matched_rate, source: :matched) if matched_rate

      single_rate = safe_single_tax_rate
      return apply_resolution(fact, adjustment, tax_rate: single_rate, source: :single_rate) if single_rate

      apply_unknown_resolution(fact, adjustment)
    end

    def apply_resolution(fact, adjustment, tax_rate:, source:)
      fact.tax_rate = tax_rate
      fact.tax_rate_source = source
      fact.attributes = fact.attributes.to_h.with_indifferent_access.merge(tax_rate: tax_rate)

      resolved = adjustment.except(INTERNAL_TAX_SOURCE_KEY)
      resolved[:tax_rate] = tax_rate
      resolved.compact.to_h.symbolize_keys
    end

    def apply_unknown_resolution(fact, adjustment)
      fact.tax_rate = nil
      fact.tax_rate_source = :unknown
      resolved = adjustment.except(INTERNAL_TAX_SOURCE_KEY, :tax_rate)
      return resolved.to_h.symbolize_keys unless risky_allocation?

      review_reasons << REVIEW_REASON
      fact.review_reasons = Array(fact.review_reasons) | [ REVIEW_REASON ]
      fact.attributes = fact.attributes.to_h.with_indifferent_access.merge(
        tax_rate: nil,
        needs_review: true,
        review_reasons: fact.review_reasons
      )

      resolved.merge(
        needs_review: true,
        review_reasons: (Array(resolved[:review_reasons]).map(&:to_s) | [ REVIEW_REASON ])
      ).to_h.symbolize_keys
    end

    def inherited_item_tax_rate(adjustment_fact)
      matching_items = Array(ownership_result.facts).select do |fact|
        fact.origin == :item &&
          normalized_rate(fact.tax_rate) &&
          same_source_token?(adjustment_fact, fact)
      end
      rates = matching_items.filter_map { |fact| normalized_rate(fact.tax_rate) }.uniq

      rates.one? ? rates.first : nil
    end

    def matched_tax_detail_rate(adjustment_amount)
      matching_details = tax_details.select do |tax_detail|
        tax_detail_target_amounts(tax_detail).include?(adjustment_amount.to_i.abs)
      end
      rates = matching_details.filter_map { |tax_detail| normalized_rate(tax_detail[:rate]) }.uniq

      rates.one? && matching_details.one? ? rates.first : nil
    end

    def tax_detail_target_amounts(tax_detail)
      net_amount = ReceiptAmountService.parse_amount(tax_detail[:net_amount]).to_i
      tax_amount = ReceiptAmountService.parse_amount(tax_detail[:amount]).to_i
      [ net_amount + tax_amount ].select(&:positive?)
    end

    def safe_single_tax_rate
      return if non_taxable_items_present?

      rates = positive_tax_rates
      rates.one? ? rates.first : nil
    end

    def risky_allocation?
      positive_tax_rates.many? ||
        (positive_tax_rates.one? && non_taxable_items_present?)
    end

    def positive_tax_rates
      @positive_tax_rates ||= (item_tax_rates + tax_detail_rates).select(&:positive?).uniq
    end

    def item_tax_rates
      items.filter_map { |item| normalized_rate(item[:tax_rate]) }
    end

    def tax_detail_rates
      tax_details.filter_map { |tax_detail| normalized_rate(tax_detail[:rate]) }
    end

    def non_taxable_items_present?
      items.any? do |item|
        rate = normalized_rate(item[:tax_rate])
        rate&.zero? && ReceiptAmountService.parse_amount(item[:line_total] || item[:price]).to_i.positive?
      end
    end

    def same_source_token?(left, right)
      left_identities = Array(left.source_refs).filter_map(&:strong_identity)
      return false if left_identities.empty?

      (left_identities & Array(right.source_refs).filter_map(&:strong_identity)).any?
    end

    def normalize_tax_rate_source(value)
      source = value.to_s.presence&.to_sym
      source if %i[explicit inherited matched single_rate unknown not_applicable].include?(source)
    end

    def correction_tax_rate_source
      return if tax_rate_correction.blank?

      tax_rate_correction[:source].to_s == "printed_tax_detail" ? :matched : :single_rate
    end

    def normalized_rate(value)
      return if value.nil? || value == ""

      rate = BigDecimal(value.to_s.delete("%"))
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError, TypeError
      nil
    end

    def normalized_hash(value)
      return value.to_h.with_indifferent_access if value.respond_to?(:to_h)

      {}.with_indifferent_access
    end
  end
end
