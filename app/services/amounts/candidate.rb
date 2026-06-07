# frozen_string_literal: true

module Amounts
  class Candidate
    ATTRIBUTES = %i[
      candidate_id
      basis
      subtotal
      tax
      purchase_total
      final_payment_total
      purchase_adjustment_total
      payment_adjustment_total
      payment_amount_sum
      tax_details
      tax_rate_groups
      rounding_mode
      rounding_scope
      score
      score_breakdown
      warnings
      hard_reject_reasons
      evidence
      computed_items
      calculation_profile
      source
    ].freeze

    attr_reader(*ATTRIBUTES)

    def initialize(**attributes)
      normalized = ATTRIBUTES.index_with { |key| attributes[key] }

      @candidate_id = normalized[:candidate_id].to_s
      @basis = normalized[:basis].to_s
      @subtotal = to_i(normalized[:subtotal])
      @tax = to_i(normalized[:tax])
      @purchase_total = to_i(normalized[:purchase_total])
      @final_payment_total = normalized[:final_payment_total].nil? ? @purchase_total : to_i(normalized[:final_payment_total])
      @purchase_adjustment_total = to_i(normalized[:purchase_adjustment_total])
      @payment_adjustment_total = to_i(normalized[:payment_adjustment_total])
      @payment_amount_sum = normalized[:payment_amount_sum].nil? ? nil : to_i(normalized[:payment_amount_sum])
      @tax_details = Array(normalized[:tax_details])
      @tax_rate_groups = Array(normalized[:tax_rate_groups])
      @rounding_mode = Amounts::Rounding.normalize_rounding_mode(normalized[:rounding_mode])
      @rounding_scope = Amounts::RoundingScope.normalize(normalized[:rounding_scope])
      @score = normalized[:score].to_i
      @score_breakdown = normalized[:score_breakdown] || {}
      @warnings = Array(normalized[:warnings]).map(&:to_sym).uniq
      @hard_reject_reasons = Array(normalized[:hard_reject_reasons]).map(&:to_sym).uniq
      @evidence = Array(normalized[:evidence])
      @computed_items = Array(normalized[:computed_items])
      @calculation_profile = normalized[:calculation_profile]
      @source = normalized[:source]&.to_sym
    end

    def accepted?
      hard_reject_reasons.empty?
    end

    def rejected?
      !accepted?
    end

    def with_score(score:, score_breakdown:)
      with(score: score, score_breakdown: score_breakdown)
    end

    def with_hard_reject_reasons(reasons)
      with(hard_reject_reasons: (hard_reject_reasons + Array(reasons)).uniq)
    end

    def with_warnings(warnings)
      with(warnings: (self.warnings + Array(warnings)).uniq)
    end

    def with(**overrides)
      self.class.new(**to_h.merge(overrides))
    end

    def to_h
      {
        candidate_id: candidate_id,
        basis: basis,
        subtotal: subtotal,
        tax: tax,
        purchase_total: purchase_total,
        final_payment_total: final_payment_total,
        purchase_adjustment_total: purchase_adjustment_total,
        payment_adjustment_total: payment_adjustment_total,
        payment_amount_sum: payment_amount_sum,
        tax_details: tax_details,
        tax_rate_groups: tax_rate_groups,
        rounding_mode: rounding_mode,
        rounding_scope: rounding_scope,
        score: score,
        score_breakdown: score_breakdown,
        warnings: warnings,
        hard_reject_reasons: hard_reject_reasons,
        evidence: evidence,
        computed_items: computed_items,
        calculation_profile: calculation_profile,
        source: source
      }.compact
    end

    private

    def to_i(value)
      Amounts::NumberParser.parse_amount(value)
    end
  end
end
