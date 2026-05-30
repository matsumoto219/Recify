# frozen_string_literal: true

module Amounts
  class CalculationProfileSnapshot
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
      {
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
        payment_adjustment_total: normalize_value(amounts[:payment_adjustment_total]),
        adjustment_tax_rate_missing_total: normalize_value(amounts[:adjustment_tax_rate_missing_total]),
        tax_detail_amount_basis: normalize_scalar(amounts[:tax_detail_amount_basis])
      }.compact
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
