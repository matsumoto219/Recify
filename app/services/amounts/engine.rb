# frozen_string_literal: true

module Amounts
  class Engine
    def initialize(receipt:, items:, tax_details:, adjustments:, payments:, context:, tax_rounding_modes:, base_result:, calculation_profile_result: nil, evaluated_candidates: nil, discount_rounding_mode: Amounts::Rounding::DISCOUNT_DEFAULT_MODE, discount_rounding_modes: nil, tax_excluded_price_conversion_enabled: true)
      @receipt = receipt
      @raw_items = Array(items)
      @tax_details = Array(tax_details)
      @adjustments = Array(adjustments)
      @payments = Array(payments)
      @context = context
      @tax_rounding_modes = Array(tax_rounding_modes).presence || Amounts::CandidateGenerator::ROUNDING_MODES
      @discount_rounding_mode = Amounts::Rounding.normalize_rounding_mode(discount_rounding_mode || Amounts::Rounding::DISCOUNT_DEFAULT_MODE)
      @discount_rounding_modes = normalize_discount_rounding_modes(discount_rounding_modes)
      @tax_excluded_price_conversion_enabled = tax_excluded_price_conversion_enabled != false
      @base_result = base_result
      @calculation_profile_result = Amounts::CalculationProfileResult.wrap(calculation_profile_result)
      @evaluated_candidates = Array(evaluated_candidates).presence
    end

    def call
      candidates = evaluated_candidates || evaluated_generated_candidates
      selector = Amounts::WinnerSelector.new(candidates)
      selected = selector.call

      Amounts::ResultAdapter.new(
        base_result: base_result,
        calculation_profile_result: calculation_profile_result,
        selected_candidate: selected,
        candidates: candidates,
        no_safe_candidate: selector.no_safe_candidate?
      ).call
    end

    private

    attr_reader :receipt, :raw_items, :tax_details, :adjustments, :payments, :context, :tax_rounding_modes, :discount_rounding_mode, :discount_rounding_modes, :tax_excluded_price_conversion_enabled, :base_result, :calculation_profile_result, :evaluated_candidates

    def evaluated_generated_candidates
      @evaluated_generated_candidates ||= Amounts::CandidatePipeline.new(
        receipt: receipt,
        items: raw_items,
        tax_details: tax_details,
        adjustments: adjustments,
        payments: payments,
        context: context,
        tax_rounding_modes: tax_rounding_modes,
        discount_rounding_modes: discount_rounding_modes,
        scoring_discount_rounding_mode: discount_rounding_mode,
        tax_excluded_price_conversion_enabled: tax_excluded_price_conversion_enabled
      ).call
    end

    def normalize_discount_rounding_modes(values)
      modes = values.nil? ? [ discount_rounding_mode ] : Array(values)
      modes.map { |mode| Amounts::Rounding.normalize_rounding_mode(mode) }.uniq.presence || [ discount_rounding_mode ]
    end
  end
end
