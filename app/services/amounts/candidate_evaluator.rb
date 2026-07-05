# frozen_string_literal: true

module Amounts
  class CandidateEvaluator
    def initialize(receipt:, items:, tax_details:, payments:, context:)
      @receipt = receipt
      @items = Array(items)
      @tax_details = Array(tax_details)
      @payments = Array(payments)
      @context = context
    end

    def call(candidates)
      Array(candidates).map do |candidate|
        scorer.call(reviewer.call(hard_rejector.call(candidate)))
      end
    end

    private

    attr_reader :receipt, :items, :tax_details, :payments, :context

    def hard_rejector
      @hard_rejector ||= Amounts::HardRejector.new(
        receipt: receipt,
        items: items,
        tax_details: tax_details,
        payments: payments
      )
    end

    def reviewer
      @reviewer ||= Amounts::CandidateConsistencyReviewer.new(
        receipt: receipt,
        items: items,
        tax_details: tax_details,
        context: context
      )
    end

    def scorer
      @scorer ||= Amounts::CandidateScorer.new(
        receipt: receipt,
        payments: payments,
        tax_details: tax_details,
        context: context
      )
    end
  end
end
