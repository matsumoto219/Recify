# frozen_string_literal: true

module Amounts
  class CandidateSnapshot
    SETTING_KEY = "amount_engine.max_candidate_snapshot_count"
    DEFAULT_CANDIDATE_COUNT = 3
    MIN_CANDIDATE_COUNT = 1
    MAX_CANDIDATE_COUNT = 20

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
        selected_candidate: selected ? snapshot_candidate(selected) : nil,
        candidates: snapshot_candidates.map do |candidate|
          snapshot_candidate(candidate)
        end
      }.compact
    end

    private

    attr_reader :selected, :candidates

    def snapshot_candidates
      ranked = candidates.sort_by { |candidate| [ candidate.rejected? ? 1 : 0, candidate.score.to_i ] }
      ([ selected ] + ranked).compact.uniq(&:candidate_id).first(snapshot_candidate_count)
    end

    def snapshot_candidate_count
      count = SystemSettings.limit_for(SETTING_KEY)
      count.clamp(MIN_CANDIDATE_COUNT, MAX_CANDIDATE_COUNT)
    rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
      DEFAULT_CANDIDATE_COUNT
    end

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
        evidence: safe_evidence(candidate.evidence),
        computed_items: safe_computed_items(candidate.computed_items)
      }.compact
    end

    def safe_computed_items(items)
      Array(items).filter_map do |item|
        next unless item.respond_to?(:to_h)

        item.to_h.symbolize_keys.slice(
          :price,
          :quantity,
          :quantity_unit,
          :original_line_total,
          :line_total,
          :discount_amount,
          :discount_rate,
          :tax_rate,
          :amount_price_present,
          :amount_quantity_present,
          :amount_line_total_present,
          :amount_discount_amount_present
        ).compact
      end
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
          :target_net_amount,
          :target_gross_amount,
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
