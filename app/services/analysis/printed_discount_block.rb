module Analysis
  class PrintedDiscountBlock
    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(proposal:, lines:, items:, profile:)
      @proposal = proposal.to_h.with_indifferent_access
      @lines = Array(lines)
      @items = Array(items)
      @profile = profile
    end

    def call
      return unless %w[receipt_discount other].include?(proposal[:kind].to_s)
      return unless proposal[:sign].to_s == "discount"
      return unless source_index&.between?(0, lines.length - 1)
      return unless proposal_text_matches?(:source_text, line_at(source_index))

      entries = ([ source_index - 2, 0 ].max..source_index).filter_map do |label_index|
        token_entry(label_index)
      end
      entries.first if entries.one?
    end

    private

    attr_reader :proposal, :lines, :items, :profile

    def source_index
      @source_index ||= Integer(proposal[:source_line_index], exception: false)
    end

    def token_entry(label_index)
      return unless discount_label?(line_at(label_index))
      return unless proposal_text_matches?(:label, line_at(label_index))
      # 中間の数量から額や率を逆算せず、小計で囲まれた負額tokenだけを金額根拠にする。
      return unless line_at(label_index + 1).match?(profile.analysis_printed_discount_quantity_pattern)
      return unless subtotal_before?(label_index) && summary_after?(label_index + 3)
      return if settlement_before?(label_index)

      money_index = label_index + 2
      text = lines[money_index].to_s
      tokens = MoneyTokenClassifier.call(
        text: text,
        money_pattern: profile.analysis_adjustment_amount_candidate_pattern,
        profile: profile
      )
      return unless tokens.one?

      token = tokens.first
      return unless token[:kind] == :money && token[:raw_text].to_s.match?(profile.adjustment_sign_evidence_pattern)
      return unless text.strip == token[:raw_text].to_s.strip
      return unless token[:amount] == ReceiptAmountService.parse_amount_or_nil(proposal[:amount])
      return unless explicit_span_matches?(money_index, token)
      return if item_owns_token?(money_index, token)

      { line: { line_index: money_index, source_text: text, normalized_text: text.unicode_normalize(:nfkc) }, token: token }
    end

    def discount_label?(text)
      text.match?(profile.analysis_printed_discount_label_pattern) &&
        !text.match?(profile.analysis_post_settlement_promo_context_pattern) &&
        !text.match?(profile.analysis_return_refund_kind_pattern) &&
        !text.match?(profile.analysis_fallback_payment_line_pattern) &&
        !text.match?(profile.ocr_tax_context_label_pattern)
    end

    def proposal_text_matches?(key, text)
      value = proposal[key].to_s
      value.blank? || value.unicode_normalize(:nfkc).gsub(/[[:space:]]+/, "") == text.gsub(/[[:space:]]+/, "")
    end

    def subtotal_before?(index)
      return false if index.zero?
      return true if line_at(index - 1).match?(profile.ocr_strict_receipt_subtotal_line_pattern)

      index >= 2 && subtotal_label?(line_at(index - 2)) && summary_amount?(line_at(index - 1))
    end

    def summary_after?(index)
      text = line_at(index)
      return true if text.match?(profile.ocr_strict_receipt_subtotal_line_pattern) || text.match?(profile.ocr_strict_receipt_summary_total_line_pattern)
      return false unless subtotal_label?(text) || text.match?(profile.ocr_strict_receipt_summary_total_label_line_pattern)
      return true if summary_amount?(line_at(index + 1))

      line_at(index + 1).match?(profile.analysis_printed_discount_quantity_pattern) && summary_amount?(line_at(index + 2))
    end

    def subtotal_label?(text)
      text.match?(profile.analysis_printed_discount_subtotal_label_pattern)
    end

    def summary_amount?(text)
      text.match?(profile.ocr_strict_receipt_summary_total_amount_line_pattern)
    end

    def settlement_before?(index)
      (0...index).any? do |line_index|
        text = line_at(line_index)
        next false if subtotal_label?(text) || text.match?(profile.ocr_strict_receipt_subtotal_line_pattern)

        text.match?(profile.analysis_post_settlement_boundary_pattern)
      end
    end

    def explicit_span_matches?(money_index, token)
      return true unless proposal.key?(:source_span_start) || proposal.key?(:source_span_end)

      source_index == money_index &&
        proposal[:source_span_start].is_a?(Integer) && proposal[:source_span_end].is_a?(Integer) &&
        proposal[:source_span_start] == token[:span_start] && proposal[:source_span_end] == token[:span_end]
    end

    def item_owns_token?(money_index, token)
      items.any? do |item|
        Array(item.to_h.with_indifferent_access[:discount_source_refs]).any? do |reference|
          next false unless reference.is_a?(Hash)

          reference = reference.with_indifferent_access
          reference[:source_line_index] == money_index && reference[:source_span_start] == token[:span_start] &&
            reference[:source_span_end] == token[:span_end] && reference[:amount] == token[:amount]
        end
      end
    end

    def line_at(index)
      return "" unless index.between?(0, lines.length - 1)

      lines[index].to_s.unicode_normalize(:nfkc).strip
    end
  end
end
