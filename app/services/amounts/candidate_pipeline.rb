# frozen_string_literal: true

module Amounts
  class CandidatePipeline
    def initialize(receipt:, items:, tax_details:, adjustments:, payments:, context:, tax_rounding_modes:, discount_rounding_modes:, scoring_discount_rounding_mode:, tax_excluded_price_conversion_enabled:)
      @receipt = receipt
      @items = Array(items)
      @tax_details = Array(tax_details)
      @adjustments = Array(adjustments)
      @payments = Array(payments)
      @context = context
      @tax_rounding_modes = tax_rounding_modes
      @discount_rounding_modes = discount_rounding_modes
      @scoring_discount_rounding_mode = scoring_discount_rounding_mode
      @tax_excluded_price_conversion_enabled = tax_excluded_price_conversion_enabled
    end

    def call
      evaluator.call(raw_candidates)
    end

    private

    attr_reader :receipt, :items, :tax_details, :adjustments, :payments, :context, :tax_rounding_modes, :discount_rounding_modes, :scoring_discount_rounding_mode, :tax_excluded_price_conversion_enabled

    def raw_candidates
      @raw_candidates ||= Amounts::CandidateGenerator.new(
        receipt: receipt,
        items: items,
        tax_details: tax_details,
        adjustments: adjustments,
        payments: payments,
        context: context,
        tax_rounding_modes: tax_rounding_modes,
        discount_rounding_modes: discount_rounding_modes,
        tax_excluded_price_conversion_enabled: tax_excluded_price_conversion_enabled
      ).call
    end

    def evaluator
      @evaluator ||= Amounts::CandidateEvaluator.new(
        receipt: receipt,
        items: scoring_items,
        tax_details: tax_details,
        payments: payments,
        context: context
      )
    end

    def scoring_items
      @scoring_items ||= Amounts::ItemTotalAggregator.new(
        items: items,
        context: context,
        discount_rounding_mode: scoring_discount_rounding_mode
      ).call[:items]
    end
  end
end
