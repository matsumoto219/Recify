module Analysis
  class ReceiptFactOwnershipResolver
    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(items:, adjustments:, payments:, tax_details:, review_reasons:, evidence_index:, profile: ReceiptAnalysisProfiles.default)
      @items = Array(items)
      @adjustments = Array(adjustments)
      @payments = Array(payments)
      @tax_details = Array(tax_details)
      @review_reasons = Array(review_reasons)
      @evidence_index = Array(evidence_index)
      @profile = profile
    end

    def call
      OwnershipResult.new(
        items: items,
        adjustments: adjustments,
        payments: payments,
        tax_details: tax_details,
        facts: build_facts,
        review_reasons: review_reasons,
        diagnostics: []
      )
    end

    private

    attr_reader :items, :adjustments, :payments, :tax_details, :review_reasons, :evidence_index, :profile

    def build_facts
      item_facts + adjustment_facts + payment_facts + tax_detail_facts
    end

    def item_facts
      items.map do |item|
        attributes = normalized_hash(item)
        build_fact(
          owner: :item,
          fact_type: :line_item,
          effect_scope: :purchase_total,
          amount: attributes[:line_total] || attributes[:price],
          attributes: attributes
        )
      end
    end

    def adjustment_facts
      adjustments.map do |adjustment|
        attributes = normalized_hash(adjustment)
        decision = OwnershipRules.classify(
          proposal: attributes,
          lines: evidence_lines,
          items: items,
          payments: payments,
          tax_details: tax_details,
          profile: profile
        )

        build_fact(
          owner: decision.owner,
          fact_type: decision.fact_type,
          kind: decision.kind || attributes[:kind],
          effect_scope: decision.effect_scope,
          amount: attributes[:amount],
          sign: decision.sign || attributes[:sign],
          tax_rate: attributes[:tax_rate],
          attributes: attributes,
          action: decision.action
        )
      end
    end

    def payment_facts
      payments.map do |payment|
        attributes = normalized_hash(payment)
        build_fact(
          owner: :payment,
          fact_type: :payment,
          effect_scope: :payment_reconciliation,
          amount: attributes[:amount],
          attributes: attributes
        )
      end
    end

    def tax_detail_facts
      tax_details.map do |tax_detail|
        attributes = normalized_hash(tax_detail)
        build_fact(
          owner: :tax_detail,
          fact_type: :tax_summary,
          effect_scope: :tax_allocation,
          amount: attributes[:amount],
          tax_rate: attributes[:rate],
          attributes: attributes
        )
      end
    end

    def build_fact(owner:, fact_type:, effect_scope:, amount:, attributes:, kind: nil, sign: nil, tax_rate: nil, action: :persist)
      OwnershipFact.new(
        owner: owner,
        fact_type: fact_type,
        kind: kind,
        effect_scope: effect_scope,
        amount: amount,
        sign: sign,
        tax_rate: tax_rate,
        tax_rate_source: tax_rate.present? ? :explicit : :unknown,
        source_refs: source_refs_for(attributes, amount),
        action: action,
        review_reasons: Array(attributes[:review_reasons]).map(&:to_s),
        diagnostics: [],
        attributes: attributes
      )
    end

    def source_refs_for(attributes, amount)
      line_index = integer_or_nil(attributes[:source_line_index])
      return [] if line_index.nil?

      line = evidence_index.find { |entry| entry[:line_index] == line_index }
      return [] if line.nil?

      token = Array(line[:tokens]).find { |candidate| candidate[:amount].to_i == amount.to_i.abs }
      [
        SourceRef.new(
          provider: attributes[:source],
          line_index: line_index,
          span_start: token&.fetch(:span_start, nil),
          span_end: token&.fetch(:span_end, nil),
          source_text: attributes[:source_text].presence || line[:source_text],
          normalized_text: line[:normalized_text],
          amount_token: token&.fetch(:amount, nil),
          amount_token_kind: token&.fetch(:kind, nil)
        )
      ]
    end

    def evidence_lines
      @evidence_lines ||= evidence_index.sort_by { |entry| entry[:line_index].to_i }.map { |entry| entry[:source_text].to_s }
    end

    def normalized_hash(value)
      return value.to_h.with_indifferent_access if value.respond_to?(:to_h)

      {}.with_indifferent_access
    end

    def integer_or_nil(value)
      Integer(value, exception: false)
    end
  end
end
