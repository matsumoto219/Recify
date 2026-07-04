# frozen_string_literal: true

module Amounts
  class CalculationProfileSnapshot
    SCHEMA_VERSION = 1
    SCORE_BREAKDOWN_KEYS = %i[
      receipt_total_delta
      receipt_subtotal_delta
      receipt_tax_delta
      payment_delta
      receipt_input_item_delta
      warning_penalty
      hard_reject_penalty
      rounding_mode_penalty
      external_tax_exact_tax_bonus
      basis_penalty
    ].freeze

    class << self
      def call(result, context: nil, rounding_mode: nil)
        new(result, context: context, rounding_mode: rounding_mode).call
      end
    end

    def initialize(result, context: nil, rounding_mode: nil)
      @result = result.respond_to?(:with_indifferent_access) ? result.with_indifferent_access : {}.with_indifferent_access
      @context = context
      @rounding_mode = rounding_mode
    end

    def call
      snapshot = {
        schema_version: SCHEMA_VERSION,
        profile: sanitized_profile,
        score: result[:calculation_profile_score],
        warnings: normalized_array(result[:warnings].presence || result[:warning_reasons]),
        mismatch_codes: normalized_array(result[:mismatch_codes]),
        blocking_mismatch_codes: normalized_array(result[:blocking_mismatch_codes]),
        warning_mismatch_codes: normalized_array(result[:warning_mismatch_codes]),
        context: normalize_scalar(context || result[:context]),
        rounding_mode: normalize_value(rounding_mode || result[:rounding_mode]),
        computed: amount_summary(result[:computed]),
        resolved: amount_summary(result[:resolved])
      }
      snapshot[:selected_candidate_status] = normalize_scalar(result[:selected_candidate_status]) if result.key?(:selected_candidate_status)
      snapshot[:safe_to_auto_complete] = normalize_value(result[:safe_to_auto_complete]) unless result[:safe_to_auto_complete].nil?

      amount_engine = sanitized_amount_engine(result[:amount_engine])
      snapshot[:amount_engine] = amount_engine if amount_engine.present?

      snapshot
    end

    private

    attr_reader :result, :context, :rounding_mode

    def sanitized_profile
      profile = result[:calculation_profile]
      return nil unless profile.respond_to?(:with_indifferent_access)

      profile = profile.with_indifferent_access
      sanitized = {
        tax_rounding_mode: normalize_scalar(profile[:tax_rounding_mode]),
        discount_rounding_mode: normalize_scalar(profile[:discount_rounding_mode]),
        receipt_tax_basis: normalize_scalar(profile[:receipt_tax_basis]),
        item_amount_basis: normalize_scalar(profile[:item_amount_basis]),
        tax_detail_amount_basis: normalize_scalar(profile[:tax_detail_amount_basis])
      }.compact

      assignments = sanitized_assignments(profile[:item_amount_basis_assignments])
      sanitized[:item_amount_basis_assignments] = assignments if assignments.present?

      sanitized
    end

    def sanitized_assignments(assignments)
      Array(assignments).filter_map do |assignment|
        next unless assignment.respond_to?(:with_indifferent_access)

        assignment = assignment.with_indifferent_access
        {
          tax_rate: normalize_value(assignment[:tax_rate]),
          basis: normalize_scalar(assignment[:basis]),
          net_amount: normalize_value(assignment[:net_amount]),
          tax_amount: normalize_value(assignment[:tax_amount]),
          gross_amount: normalize_value(assignment[:gross_amount])
        }.compact
      end
    end

    def amount_summary(amounts)
      amounts = amounts.respond_to?(:with_indifferent_access) ? amounts.with_indifferent_access : {}.with_indifferent_access

      {
        total_amount: normalize_value(amounts[:total]),
        subtotal_amount: normalize_value(amounts[:subtotal]),
        tax_amount: normalize_value(amounts[:tax]),
        adjusted_item_total: normalize_value(amounts[:adjusted_item_total]),
        adjustment_discount_total: normalize_value(amounts[:adjustment_discount_total]),
        adjustment_surcharge_total: normalize_value(amounts[:adjustment_surcharge_total]),
        purchase_adjustment_total: normalize_value(amounts[:purchase_adjustment_total]),
        payment_adjustment_total: normalize_value(amounts[:payment_adjustment_total]),
        payment_amount_sum: normalize_value(amounts[:payment_amount_sum]),
        final_payment_total: normalize_value(amounts[:final_payment_total]),
        adjustment_tax_rate_missing_total: normalize_value(amounts[:adjustment_tax_rate_missing_total]),
        tax_detail_amount_basis: normalize_scalar(amounts[:tax_detail_amount_basis])
      }.compact
    end

    def sanitized_amount_engine(value)
      return nil unless value.respond_to?(:with_indifferent_access)

      engine = value.with_indifferent_access
      {
        schema_version: normalize_value(engine[:schema_version]),
        selected_candidate_id: normalize_scalar(engine[:selected_candidate_id]),
        selected_basis: normalize_scalar(engine[:selected_basis]),
        selected_candidate_status: normalize_scalar(engine[:selected_candidate_status]),
        no_safe_candidate: normalize_value(engine[:no_safe_candidate]),
        selected_candidate: sanitized_engine_candidate(engine[:selected_candidate]),
        candidates: sanitized_engine_candidates(engine[:candidates])
      }.compact
    end

    def sanitized_engine_candidates(candidates)
      Array(candidates).filter_map do |candidate|
        sanitized_engine_candidate(candidate)
      end
    end

    def sanitized_engine_candidate(candidate)
      return nil unless candidate.respond_to?(:with_indifferent_access)

      candidate = candidate.with_indifferent_access
      {
        candidate_id: normalize_scalar(candidate[:candidate_id]),
        basis: normalize_scalar(candidate[:basis]),
        subtotal: normalize_value(candidate[:subtotal]),
        tax: normalize_value(candidate[:tax]),
        purchase_total: normalize_value(candidate[:purchase_total]),
        final_payment_total: normalize_value(candidate[:final_payment_total]),
        purchase_adjustment_total: normalize_value(candidate[:purchase_adjustment_total]),
        payment_adjustment_total: normalize_value(candidate[:payment_adjustment_total]),
        payment_amount_sum: normalize_value(candidate[:payment_amount_sum]),
        rounding_mode: normalize_scalar(candidate[:rounding_mode]),
        rounding_scope: normalize_scalar(candidate[:rounding_scope]),
        score: normalize_value(candidate[:score]),
        score_breakdown: sanitized_score_breakdown(candidate[:score_breakdown]),
        warnings: normalized_array(candidate[:warnings]),
        hard_reject_reasons: normalized_array(candidate[:hard_reject_reasons]),
        evidence: sanitized_engine_evidence(candidate[:evidence]),
        computed_items: sanitized_engine_computed_items(candidate[:computed_items])
      }.compact
    end

    def sanitized_engine_computed_items(items)
      Array(items).filter_map do |item|
        next unless item.respond_to?(:with_indifferent_access)

        item = item.with_indifferent_access
        normalize_value(
          item.slice(
            :price,
            :quantity,
            :quantity_unit_code,
            :original_line_total,
            :line_total,
            :discount_amount,
            :discount_rate,
            :tax_rate,
            :amount_price_present,
            :amount_quantity_present,
            :amount_line_total_present,
            :amount_discount_amount_present
          )
        )
      end
    end

    def sanitized_score_breakdown(score_breakdown)
      return nil unless score_breakdown.respond_to?(:with_indifferent_access)

      normalize_value(score_breakdown.with_indifferent_access.slice(*SCORE_BREAKDOWN_KEYS))
    end

    def sanitized_engine_evidence(evidence)
      Array(evidence).filter_map do |entry|
        next unless entry.respond_to?(:with_indifferent_access)

        entry = entry.with_indifferent_access
        normalize_value(
          entry.slice(
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
            :payment_amount_mismatch_suppressed,
            :suppressed_reason,
            :effect,
            :kind,
            :sign,
            :tax_rate
          )
        )
      end
    end

    def normalized_array(value)
      Array(value).filter_map do |item|
        normalized = normalize_scalar(item)
        normalized.presence
      end
    end

    def normalize_value(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child_value), memo|
          normalized = normalize_value(child_value)
          memo[key.to_s] = normalized unless normalized.nil?
        end
      when Array
        value.map { |item| normalize_value(item) }
      when BigDecimal
        value.to_s("F")
      when Symbol
        value.to_s
      else
        value
      end
    end

    def normalize_scalar(value)
      normalized = normalize_value(value)
      normalized.is_a?(String) ? normalized : normalized&.to_s
    end
  end
end
