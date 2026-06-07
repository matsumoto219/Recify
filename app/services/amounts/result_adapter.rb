# frozen_string_literal: true

module Amounts
  class ResultAdapter
    def initialize(legacy_result:, selected_candidate:, candidates:)
      @legacy_result = legacy_result
      @selected_candidate = selected_candidate
      @candidates = Array(candidates)
    end

    def call
      result = legacy_result.deep_dup
      result[:amount_engine] = Amounts::CandidateSnapshot.call(selected: selected_candidate, candidates: candidates)

      return result unless selected_candidate

      if selected_candidate.source == :legacy && selected_candidate.accepted?
        enrich_legacy_result!(result)
      else
        apply_candidate_result!(result)
      end

      result
    end

    private

    attr_reader :legacy_result, :selected_candidate, :candidates

    def enrich_legacy_result!(result)
      computed = result[:computed] ||= {}
      computed[:purchase_total] ||= selected_candidate.purchase_total
      computed[:final_payment_total] ||= selected_candidate.final_payment_total
      computed[:purchase_adjustment_total] ||= selected_candidate.purchase_adjustment_total
      computed[:payment_amount_sum] ||= selected_candidate.payment_amount_sum
      apply_legacy_payment_mismatch!(result)
    end

    def apply_legacy_payment_mismatch!(result)
      return unless selected_candidate.warnings.include?(:payment_amount_mismatch)

      result[:inconsistencies] = (existing_inconsistencies(result) + [ :payment_amount_mismatch ]).uniq
      result[:blocking_inconsistencies] = Amounts::MismatchSeverity.blocking(result[:inconsistencies])
      result[:warning_inconsistencies] = Amounts::MismatchSeverity.warning(result[:inconsistencies])
      result[:warning_reasons] = result[:warning_inconsistencies].map(&:to_s)
      result[:mismatch_codes] = mismatch_codes_for(result[:inconsistencies])
      result[:blocking_mismatch_codes] = mismatch_codes_for(result[:blocking_inconsistencies])
      result[:warning_mismatch_codes] = mismatch_codes_for(result[:warning_inconsistencies])
      result[:mismatch_messages] = mismatch_messages_for(result[:inconsistencies])
      result[:review_reasons] = (Array(result[:review_reasons]) + [ "payment_amount_mismatch" ]).uniq
      result[:needs_review] = true
    end

    def existing_inconsistencies(result)
      inconsistencies = Array(result[:inconsistencies])
      return inconsistencies if inconsistencies.present?

      Array(result[:blocking_inconsistencies]) + Array(result[:warning_inconsistencies])
    end

    def apply_candidate_result!(result)
      result[:resolved] = {
        subtotal: selected_candidate.subtotal,
        tax: selected_candidate.tax,
        total: selected_candidate.purchase_total,
        tax_rate: resolved_tax_rate
      }

      result[:computed] = (result[:computed] || {}).merge(
        subtotal: selected_candidate.subtotal,
        tax: selected_candidate.tax,
        total: selected_candidate.purchase_total,
        tax_rate: resolved_tax_rate,
        item_amount_basis: item_amount_basis_for(selected_candidate),
        amount_engine_candidate_id: selected_candidate.candidate_id,
        amount_engine_basis: selected_candidate.basis,
        purchase_total: selected_candidate.purchase_total,
        final_payment_total: selected_candidate.final_payment_total,
        purchase_adjustment_total: selected_candidate.purchase_adjustment_total,
        payment_adjustment_total: selected_candidate.payment_adjustment_total,
        payment_amount_sum: selected_candidate.payment_amount_sum,
        tax_rate_groups: selected_candidate.tax_rate_groups,
        items: selected_candidate.computed_items
      )
      result[:tax_details] = selected_candidate.tax_details

      policy = Amounts::ReviewPolicy.new(
        candidate: selected_candidate,
        existing_inconsistencies: []
      ).call

      result[:inconsistencies] = policy[:inconsistencies]
      result[:blocking_inconsistencies] = Amounts::MismatchSeverity.blocking(result[:inconsistencies])
      result[:warning_inconsistencies] = Amounts::MismatchSeverity.warning(result[:inconsistencies])
      result[:warning_reasons] = result[:warning_inconsistencies].map(&:to_s)
      result[:mismatch_codes] = mismatch_codes_for(result[:inconsistencies])
      result[:blocking_mismatch_codes] = mismatch_codes_for(result[:blocking_inconsistencies])
      result[:warning_mismatch_codes] = mismatch_codes_for(result[:warning_inconsistencies])
      result[:mismatch_messages] = mismatch_messages_for(result[:inconsistencies])
      result[:review_reasons] = policy[:review_reasons]
      result[:needs_review] = policy[:needs_review]
      result[:calculation_profile_score] = selected_candidate.score
    end

    def item_amount_basis_for(candidate)
      case candidate.basis
      when "external_tax_from_receipt", "items_as_tax_excluded"
        :line_total_as_net
      when "mixed_by_tax_rate_group"
        :mixed_by_tax_rate_group
      else
        :line_total_as_recorded
      end
    end

    def resolved_tax_rate
      rates = selected_candidate.tax_rate_groups.filter_map do |group|
        rate = group[:rate]
        rate if rate.respond_to?(:positive?) && rate.positive?
      end.uniq

      rates.one? ? rates.first : nil
    end

    def mismatch_codes_for(inconsistencies)
      Array(inconsistencies).filter_map { |inconsistency| Amounts::MismatchCodes.code(inconsistency.to_sym) }
    end

    def mismatch_messages_for(inconsistencies)
      Array(inconsistencies).filter_map do |inconsistency|
        I18n.t("enums.receipt_item.review_reason.#{inconsistency}", default: nil)
      end
    end
  end
end
