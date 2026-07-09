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
      OwnershipConflictResolver.call(
        facts: build_facts,
        review_reasons: review_reasons,
        profile: profile
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
          tax_rate: attributes[:tax_rate],
          attributes: attributes,
          origin: :item
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
          action: decision.action,
          origin: :adjustment
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
          attributes: attributes,
          origin: :payment
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
          attributes: attributes,
          origin: :tax_detail
        )
      end
    end

    def build_fact(owner:, fact_type:, effect_scope:, amount:, attributes:, origin:, kind: nil, sign: nil, tax_rate: nil, action: :persist)
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
        attributes: attributes,
        origin: origin
      )
    end

    def source_refs_for(attributes, amount)
      amount_value = amount.to_i.abs
      return [] unless amount_value.positive?

      source_indexes = source_line_indexes(attributes)
      return [] if source_indexes.empty?

      token_entries = token_entries_near(source_indexes, amount_value)
      token_entry = explicit_span_token_entry(attributes, token_entries) || unique_token_entry(token_entries)
      return [] if token_entry.nil?

      line = token_entry[:line]
      token = token_entry[:token]
      [ build_source_ref(attributes, line, token) ]
    end

    def source_line_indexes(attributes)
      explicit_index = integer_or_nil(attributes[:source_line_index] || attributes[:source_index])
      return [ explicit_index ] unless explicit_index.nil?

      source_texts = %i[source_text raw_text suggested_name label method description].filter_map do |key|
        compact_evidence_text(attributes[key]).presence
      end
      return [] if source_texts.empty?

      evidence_index.filter_map do |entry|
        normalized_line = compact_evidence_text(entry[:source_text])
        next if normalized_line.blank?
        next unless source_texts.any? do |source_text|
          normalized_line.include?(source_text) || source_text.include?(normalized_line)
        end

        entry[:line_index]
      end
    end

    def token_entries_near(source_indexes, amount)
      nearby_indexes = source_indexes.flat_map { |index| [ index, index + 1, index - 1 ] }.select { |index| index >= 0 }.uniq
      evidence_index.flat_map do |line|
        next [] unless nearby_indexes.include?(line[:line_index])

        Array(line[:tokens]).filter_map do |token|
          next unless token[:amount].to_i == amount
          next unless %i[money bare_number].include?(token[:kind]&.to_sym)

          { line: line, token: token }
        end
      end
    end

    def explicit_span_token_entry(attributes, token_entries)
      span_start = integer_or_nil(attributes[:source_span_start] || attributes[:span_start])
      span_end = integer_or_nil(attributes[:source_span_end] || attributes[:span_end])
      return if span_start.nil? || span_end.nil?

      token_entries.find do |entry|
        entry[:token][:span_start].to_i == span_start && entry[:token][:span_end].to_i == span_end
      end
    end

    def unique_token_entry(token_entries)
      return token_entries.first if token_entries.one?

      money_entries = token_entries.select { |entry| entry[:token][:kind]&.to_sym == :money }
      money_entries.one? ? money_entries.first : nil
    end

    def build_source_ref(attributes, line, token)
      SourceRef.new(
        provider: attributes[:source_provider].presence || :ocr_line,
        field_path: attributes[:source_field_path] || attributes[:field_path],
        line_index: line[:line_index],
        span_start: token[:span_start],
        span_end: token[:span_end],
        source_text: line[:source_text],
        normalized_text: line[:normalized_text],
        amount_token: token[:amount],
        amount_token_kind: token[:kind]
      )
    end

    def evidence_lines
      @evidence_lines ||= evidence_index.sort_by { |entry| entry[:line_index].to_i }.map { |entry| entry[:source_text].to_s }
    end

    def normalized_hash(value)
      return value.to_h.with_indifferent_access if value.respond_to?(:to_h)

      {}.with_indifferent_access
    end

    def compact_evidence_text(value)
      value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[[:space:]　,，¥￥:：]+/, "")
    end

    def integer_or_nil(value)
      Integer(value, exception: false)
    end
  end
end
