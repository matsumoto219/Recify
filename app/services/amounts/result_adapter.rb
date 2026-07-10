# frozen_string_literal: true

module Amounts
  class ResultAdapter
    def initialize(base_result:, selected_candidate:, candidates:, calculation_profile_result: nil, no_safe_candidate: nil)
      @base_result = base_result
      @selected_candidate = selected_candidate
      @candidates = Array(candidates)
      @calculation_profile_result = Amounts::CalculationProfileResult.wrap(calculation_profile_result)
      @no_safe_candidate = no_safe_candidate
    end

    def call
      result = engine_result_template
      result[:amount_engine] = Amounts::CandidateSnapshot.call(
        selected: selected_candidate,
        candidates: candidates,
        no_safe_candidate: no_safe_candidate?
      )
      result[:selected_candidate_status] = selected_candidate_status if selected_candidate_status
      result[:safe_to_auto_complete] = false

      return result unless selected_candidate

      apply_candidate_result!(result)
      result[:safe_to_auto_complete] = safe_to_auto_complete?(result)

      result
    end

    private

    attr_reader :base_result, :selected_candidate, :candidates, :calculation_profile_result, :no_safe_candidate

    def engine_result_template
      inconsistencies = normalized_base_inconsistencies

      {
        context: base_context,
        rounding_mode: base_value(:rounding_mode, {}),
        computed: base_value(:computed, {}),
        resolved: base_value(:resolved, {}),
        tax_details: base_value(:tax_details, []),
        inconsistencies: inconsistencies,
        blocking_inconsistencies: Amounts::MismatchSeverity.blocking(inconsistencies),
        warning_inconsistencies: Amounts::MismatchSeverity.warning(inconsistencies),
        warning_reasons: Amounts::MismatchSeverity.warning(inconsistencies).map(&:to_s),
        mismatch_codes: mismatch_codes_for(inconsistencies),
        blocking_mismatch_codes: mismatch_codes_for(Amounts::MismatchSeverity.blocking(inconsistencies)),
        warning_mismatch_codes: mismatch_codes_for(Amounts::MismatchSeverity.warning(inconsistencies)),
        mismatch_messages: mismatch_messages_for(inconsistencies),
        calculation_profile: calculation_profile_result.profile,
        calculation_profile_score: calculation_profile_result.score,
        calculation_profile_candidates: calculation_profile_result.candidates,
        needs_review: Amounts::MismatchSeverity.needs_review?(inconsistencies)
      }
    end

    def normalized_base_inconsistencies
      Array(base_value(:inconsistencies, [])).map(&:to_sym)
    end

    def selected_candidate_status
      return nil unless selected_candidate

      selected_candidate.rejected? ? "rejected" : "accepted"
    end

    def no_safe_candidate?
      return no_safe_candidate unless no_safe_candidate.nil?

      candidates.present? && candidates.none?(&:accepted?)
    end

    def safe_to_auto_complete?(result)
      selected_candidate_status == "accepted" &&
        no_safe_candidate? == false &&
        result[:needs_review] == false
    end

    def base_value(key, default = nil)
      return default unless base_result.respond_to?(:[])

      value = base_result[key]
      value = base_result[key.to_s] if value.nil?
      value.nil? ? default : value
    end

    def apply_candidate_result!(result)
      resolved = resolved_values
      result[:resolved] = resolved

      result[:computed] = (result[:computed] || {}).merge(
        subtotal: resolved[:subtotal],
        tax: resolved[:tax],
        total: resolved[:total],
        tax_rate: resolved[:tax_rate],
        receipt_tax_basis: computed_basis_value(:receipt_tax_basis, candidate_profile_resolver.receipt_tax_basis),
        item_amount_basis: computed_item_amount_basis(selected_candidate, resolved),
        tax_detail_amount_basis: computed_basis_value(:tax_detail_amount_basis, candidate_profile_resolver.tax_detail_amount_basis),
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
      result[:tax_details] = negative_purchase_candidate? ? [] : selected_candidate.tax_details

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
      apply_profile_warning_projection!(result)
      result[:review_reasons] = policy[:review_reasons]
      result[:needs_review] = policy[:needs_review]
      result[:calculation_profile_score] = selected_candidate.score unless preserve_calculation_profile_output?
    end

    def apply_profile_warning_projection!(result)
      extra_warnings = profile_warning_only_inconsistencies - Array(result[:warning_inconsistencies])
      return if extra_warnings.blank?

      result[:inconsistencies] = (Array(result[:inconsistencies]) + extra_warnings).uniq
      result[:blocking_inconsistencies] = Amounts::MismatchSeverity.blocking(result[:inconsistencies])
      result[:warning_inconsistencies] = Amounts::MismatchSeverity.warning(result[:inconsistencies])
      result[:warning_reasons] = result[:warning_inconsistencies].map(&:to_s)
      result[:mismatch_codes] = mismatch_codes_for(result[:inconsistencies])
      result[:blocking_mismatch_codes] = mismatch_codes_for(result[:blocking_inconsistencies])
      result[:warning_mismatch_codes] = mismatch_codes_for(result[:warning_inconsistencies])
      result[:mismatch_messages] = mismatch_messages_for(result[:inconsistencies])
    end

    def profile_warning_only_inconsistencies
      return [] unless external_tax_warning_projection_candidate?

      Array(calculation_profile_result.warnings)
        .map(&:to_sym)
        .select { |warning| warning == :price_tax_inclusion_uncertain }
    end

    def external_tax_warning_projection_candidate?
      selected_candidate.basis == "external_tax_from_receipt" &&
        calculation_profile_value(:receipt_tax_basis).to_s == "tax_added_to_subtotal" &&
        calculation_profile_value(:item_amount_basis).to_s == "line_total_as_net"
    end

    def resolved_values
      return empty_nonnegative_review_draft if negative_purchase_candidate?

      preserved = receipt_input_resolved_values
      return preserved if preserved

      {
        subtotal: selected_candidate.subtotal,
        tax: selected_candidate.tax,
        total: selected_candidate.purchase_total,
        tax_rate: resolved_tax_rate
      }
    end

    def negative_purchase_candidate?
      [
        selected_candidate.subtotal,
        selected_candidate.tax,
        selected_candidate.purchase_total
      ].any? { |amount| amount.to_i.negative? }
    end

    def empty_nonnegative_review_draft
      {
        subtotal: 0,
        tax: 0,
        total: 0,
        tax_rate: nil
      }
    end

    def receipt_input_resolved_values
      return nil unless selected_candidate.basis == "receipt_input_preserved"
      profile = selected_candidate.calculation_profile
      return nil unless profile.respond_to?(:key?)

      values = profile[:receipt_input_resolved] || profile["receipt_input_resolved"]
      return nil unless values.respond_to?(:to_h)

      values.to_h.symbolize_keys.slice(:subtotal, :tax, :total, :tax_rate)
    end

    def preserve_calculation_profile_output?
      %i[manual edit_save].include?(base_context)
    end

    def computed_basis_value(key, fallback)
      return fallback unless preserve_calculation_profile_output?
      return :line_total_as_recorded if key == :item_amount_basis

      fallback
    end

    def computed_item_amount_basis(candidate, resolved)
      fallback = candidate_profile_resolver.item_amount_basis
      profile_value = calculation_profile_value(:item_amount_basis)
      return computed_basis_value(:item_amount_basis, fallback) unless profile_value.to_s == "mixed_by_tax_rate_group"
      return computed_basis_value(:item_amount_basis, fallback) unless candidate.basis == "mixed_by_tax_rate_group"
      return :line_total_as_recorded if candidate.warnings.include?(:price_tax_inclusion_uncertain)
      return computed_basis_value(:item_amount_basis, fallback) unless candidate_totals_match_resolved?(candidate, resolved)

      :mixed_by_tax_rate_group
    end

    def candidate_profile_resolver
      @candidate_profile_resolver ||= Amounts::CandidateProfileResolver.new(selected_candidate)
    end

    def calculation_profile_value(key)
      profile = calculation_profile_result.profile
      return nil unless profile.respond_to?(:key?)

      profile[key] || profile[key.to_s]
    end

    def candidate_totals_match_resolved?(candidate, resolved)
      candidate.subtotal.to_i == resolved[:subtotal].to_i &&
        candidate.tax.to_i == resolved[:tax].to_i &&
        candidate.purchase_total.to_i == resolved[:total].to_i
    end

    def base_context
      base_value(:context).to_s.to_sym
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
