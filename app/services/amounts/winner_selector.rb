# frozen_string_literal: true

module Amounts
  class WinnerSelector
    COMPETING_EXACT_BASIS_WARNING = :competing_exact_basis_candidate
    MIXED_BASIS_SEARCH_TRUNCATED_WARNING = :mixed_basis_search_truncated
    BASIS_TIE_BREAK_PRIORITY = {
      "receipt_input_preserved" => 0,
      "external_tax_from_receipt" => 10,
      "items_as_tax_excluded" => 20,
      "items_as_tax_included" => 30,
      "mixed_by_tax_rate_group" => 40,
      "printed_tax_details_gross" => 50,
      "printed_tax_details_net" => 60,
      "printed_tax_details_raw_sum" => 70,
      "incomplete_tax_details_receipt_tax" => 80
    }.freeze
    ROUNDING_MODE_TIE_BREAK_PRIORITY = {
      floor: 0,
      round: 10,
      ceil: 20
    }.freeze
    ROUNDING_SCOPE_TIE_BREAK_PRIORITY = {
      per_item: 0,
      per_receipt: 10
    }.freeze
    EXACT_SCORE_BREAKDOWN_KEYS = %i[
      receipt_total_delta
      receipt_subtotal_delta
      receipt_tax_delta
      payment_delta
      receipt_input_item_delta
    ].freeze

    def initialize(candidates)
      @candidates = Array(candidates)
    end

    def call
      pool = selectable_candidates

      selected = pool.min_by do |candidate|
        tie_break_key(candidate)
      end

      selected = mark_competing_exact_basis(selected)
      mark_mixed_basis_search_truncated(selected)
    end

    def no_safe_candidate?
      candidates.present? && candidates.none?(&:accepted?)
    end

    private

    attr_reader :candidates

    def selectable_candidates
      candidates.reject(&:rejected?).presence || candidates
    end

    def tie_break_key(candidate)
      [
        candidate.score.to_i,
        candidate.rejected? ? 1 : 0,
        warning_priority(candidate),
        evidence_priority(candidate),
        basis_priority(candidate),
        rounding_mode_priority(candidate),
        rounding_scope_priority(candidate),
        candidate.candidate_id
      ]
    end

    def warning_priority(candidate)
      Amounts::MismatchSeverity.blocking(candidate.warnings).size * 1_000 +
        candidate.warnings.size
    end

    def evidence_priority(candidate)
      candidate.evidence.present? ? 0 : 1
    end

    def basis_priority(candidate)
      BASIS_TIE_BREAK_PRIORITY.fetch(candidate.basis.to_s, 999)
    end

    def rounding_mode_priority(candidate)
      ROUNDING_MODE_TIE_BREAK_PRIORITY.fetch(candidate.rounding_mode, 999)
    end

    def rounding_scope_priority(candidate)
      ROUNDING_SCOPE_TIE_BREAK_PRIORITY.fetch(candidate.rounding_scope, 999)
    end

    def mark_competing_exact_basis(selected)
      return selected unless competing_exact_basis_candidate?(selected)

      selected.with_warnings([ COMPETING_EXACT_BASIS_WARNING ])
    end

    def mark_mixed_basis_search_truncated(selected)
      return selected unless selected
      return selected unless candidates.any? { |candidate| candidate.warnings.include?(MIXED_BASIS_SEARCH_TRUNCATED_WARNING) }

      selected.with_warnings([ MIXED_BASIS_SEARCH_TRUNCATED_WARNING ])
    end

    def competing_exact_basis_candidate?(selected)
      return false unless printed_net_price_tax_candidate?(selected)
      return false unless exact_candidate?(selected)

      candidates.any? do |candidate|
        next false if candidate.candidate_id == selected.candidate_id
        next false if candidate.basis == selected.basis
        next false if candidate.warnings.present?

        exact_candidate?(candidate)
      end
    end

    def printed_net_price_tax_candidate?(candidate)
      candidate&.basis.to_s == "printed_tax_details_net" &&
        candidate.warnings.include?(:price_tax_inclusion_uncertain)
    end

    def exact_candidate?(candidate)
      return false unless candidate&.accepted?
      return false unless candidate.score_breakdown.respond_to?(:key?) && candidate.score_breakdown.present?

      EXACT_SCORE_BREAKDOWN_KEYS.all? do |key|
        score_value(candidate.score_breakdown, key).zero?
      end
    end

    def score_value(score_breakdown, key)
      return 0 unless score_breakdown.respond_to?(:[])

      value = score_breakdown[key]
      value = score_breakdown[key.to_s] if value.nil?
      value.to_i
    end
  end
end
