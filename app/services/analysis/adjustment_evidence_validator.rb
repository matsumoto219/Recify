module Analysis
  class AdjustmentEvidenceValidator
    Result = Struct.new(
      :status,
      :reason,
      :review_required,
      :owner,
      :fact_type,
      :effect_scope,
      :kind,
      :sign,
      :action,
      keyword_init: true
    ) do
      def accepted?
        status == :accepted
      end
    end

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(proposal:, source:, lines:, evidence_index:, items:, payments:, tax_details:, profile:)
      @proposal = normalized_hash(proposal)
      @lines = Array(lines)
      @evidence_index = Array(evidence_index)
      @items = Array(items)
      @payments = Array(payments)
      @tax_details = Array(tax_details)
      @profile = profile
    end

    def call
      return reject(:invalid_amount, review_required: true) unless amount.positive?
      return reject(:source_line_index_missing, review_required: true) if source_line_index.nil?
      return reject(:source_line_index_out_of_range, review_required: true) unless source_line_index.between?(0, lines.length - 1)
      return reject(:source_text_mismatch, review_required: true) unless source_text_matches_line?
      decision = ownership_decision
      return reject_decision(decision) if decision.action == :reject_false_positive
      return reject(:amount_evidence_missing, review_required: true) unless amount_evidence_supported?

      return reject_decision(decision) unless decision.accepted_proposal?

      accepted_decision(decision)
    end

    private

    attr_reader :proposal, :lines, :evidence_index, :items, :payments, :tax_details, :profile

    def amount
      @amount ||= ReceiptAmountService.parse_amount(proposal[:amount]).to_i.abs
    end

    def source_line_index
      @source_line_index ||= Integer(proposal[:source_line_index], exception: false)
    end

    def source_line
      lines[source_line_index].to_s
    end

    def source_text_matches_line?
      explicit_source = proposal[:source_text].to_s.strip
      return true if explicit_source.blank?

      normalized_source = compact_text(explicit_source)
      normalized_line = compact_text(source_line)
      normalized_source == normalized_line ||
        normalized_source.include?(normalized_line) ||
        normalized_line.include?(normalized_source)
    end

    def amount_evidence_supported?
      evidence_entries.any? do |entry|
        Array(entry[:tokens]).any? do |token|
          next false unless token[:amount].to_i == amount
          next true if token[:kind] == :money
          next false unless token[:kind] == :bare_number

          explicit_adjustment_context?
        end
      end
    end

    def evidence_entries
      indexes = [ source_line_index - 1, source_line_index, source_line_index + 1 ]
      evidence_index.select { |entry| indexes.include?(entry[:line_index]) }
    end

    def ownership_decision
      OwnershipRules.classify(
        proposal: proposal.merge(amount: amount, source_line_index: source_line_index),
        lines: lines,
        items: items,
        payments: payments,
        tax_details: tax_details,
        profile: profile
      )
    end

    def explicit_adjustment_context?
      text = [ proposal[:label], proposal[:source_text], source_line ].compact.join(" ")
      text.match?(profile.ocr_adjustment_discount_label_pattern) ||
        text.match?(profile.ocr_adjustment_surcharge_label_pattern) ||
        text.match?(profile.ocr_payment_adjustment_discount_label_pattern) ||
        text.match?(profile.ocr_point_usage_adjustment_label_pattern) ||
        text.match?(/[▲△\-−]/)
    end

    def compact_text(value)
      value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[[:space:]　,，¥￥:：]+/, "")
    end

    def normalized_hash(value)
      return value.to_h.with_indifferent_access if value.respond_to?(:to_h)

      {}.with_indifferent_access
    end

    def reject(reason, review_required:)
      Result.new(status: :rejected, reason: reason, review_required: review_required)
    end

    def reject_decision(decision)
      result_for(decision, status: :rejected)
    end

    def accepted_decision(decision)
      result_for(decision, status: :accepted)
    end

    def result_for(decision, status:)
      Result.new(
        status: status,
        reason: decision.reason,
        review_required: decision.review_required,
        owner: decision.owner,
        fact_type: decision.fact_type,
        effect_scope: decision.effect_scope,
        kind: decision.kind,
        sign: decision.sign,
        action: decision.action
      )
    end
  end
end
