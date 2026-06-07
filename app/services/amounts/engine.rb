# frozen_string_literal: true

module Amounts
  class Engine
    def initialize(receipt:, items:, tax_details:, adjustments:, payments:, context:, tax_rounding_modes:, legacy_result:)
      @receipt = receipt
      @items = Array(items)
      @tax_details = Array(tax_details)
      @adjustments = Array(adjustments)
      @payments = Array(payments)
      @context = context
      @tax_rounding_modes = Array(tax_rounding_modes).presence || Amounts::CandidateGenerator::ROUNDING_MODES
      @legacy_result = legacy_result
    end

    def call
      candidates = generated_candidates.map { |candidate| hard_rejector.call(candidate) }
      candidates = candidates.map { |candidate| scorer.call(candidate) }
      selected = Amounts::WinnerSelector.new(candidates, context: context, receipt: receipt).call

      Amounts::ResultAdapter.new(
        legacy_result: legacy_result,
        selected_candidate: selected,
        candidates: candidates
      ).call
    end

    private

    attr_reader :receipt, :items, :tax_details, :adjustments, :payments, :context, :tax_rounding_modes, :legacy_result

    def generated_candidates
      @generated_candidates ||= Amounts::CandidateGenerator.new(
        receipt: receipt,
        items: items,
        tax_details: tax_details,
        adjustments: adjustments,
        payments: payments,
        context: context,
        tax_rounding_modes: tax_rounding_modes,
        legacy_result: legacy_result
      ).call
    end

    def hard_rejector
      @hard_rejector ||= Amounts::HardRejector.new(
        receipt: receipt,
        items: items,
        tax_details: tax_details,
        payments: payments
      )
    end

    def scorer
      @scorer ||= Amounts::CandidateScorer.new(
        receipt: receipt,
        payments: payments,
        tax_details: tax_details
      )
    end
  end
end
