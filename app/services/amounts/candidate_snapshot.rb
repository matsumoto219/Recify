# frozen_string_literal: true

module Amounts
  class CandidateSnapshot
    MAX_CANDIDATES = 5

    class << self
      def call(selected:, candidates:)
        new(selected: selected, candidates: candidates).call
      end
    end

    def initialize(selected:, candidates:)
      @selected = selected
      @candidates = Array(candidates)
    end

    def call
      {
        selected_candidate_id: selected&.candidate_id,
        selected_basis: selected&.basis,
        candidates: candidates.sort_by { |candidate| [ candidate.rejected? ? 1 : 0, candidate.score.to_i ] }.first(MAX_CANDIDATES).map do |candidate|
          snapshot_candidate(candidate)
        end
      }.compact
    end

    private

    attr_reader :selected, :candidates

    def snapshot_candidate(candidate)
      {
        candidate_id: candidate.candidate_id,
        basis: candidate.basis,
        subtotal: candidate.subtotal,
        tax: candidate.tax,
        purchase_total: candidate.purchase_total,
        final_payment_total: candidate.final_payment_total,
        purchase_adjustment_total: candidate.purchase_adjustment_total,
        payment_adjustment_total: candidate.payment_adjustment_total,
        payment_amount_sum: candidate.payment_amount_sum,
        rounding_mode: candidate.rounding_mode,
        rounding_scope: candidate.rounding_scope,
        score: candidate.score,
        score_breakdown: candidate.score_breakdown,
        warnings: candidate.warnings,
        hard_reject_reasons: candidate.hard_reject_reasons,
        evidence: safe_evidence(candidate.evidence)
      }.compact
    end

    def safe_evidence(evidence)
      Array(evidence).filter_map do |entry|
        next unless entry.respond_to?(:to_h)

        entry.to_h.symbolize_keys.slice(
          :source,
          :index,
          :rate,
          :basis,
          :formula,
          :amount,
          :net_amount,
          :gross_amount,
          :tax_amount,
          :purchase_total,
          :final_payment_total,
          :payment_amount_sum,
          :payment_delta,
          :effect,
          :kind,
          :sign,
          :tax_rate
        )
      end
    end
  end
end
