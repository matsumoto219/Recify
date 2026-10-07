# frozen_string_literal: true

module Receipts
  class TaxDetailDiagnosticQuery
    Result = Data.define(:state, :reason, :applicable) do
      def applicable?
        applicable
      end
    end

    def self.call(receipt:)
      new(receipt:).call
    end

    def initialize(receipt:)
      @receipt = receipt
    end

    def call
      return result(state: :unavailable, reason: :not_applicable, applicable: false) unless receipt&.persisted?

      saved_receipt = Receipt.includes(:receipt_items, :receipt_adjustments, :receipt_payments, :receipt_tax_details)
        .find_by!(id: receipt.id, user_id: receipt.user_id)
      return result(state: :unavailable, reason: :not_applicable, applicable: false) if saved_receipt.receipt_tax_details.empty?

      input = Receipts::Editing.build_input(receipt: saved_receipt, permitted: {})
      diagnosis = ReceiptAmountService.tax_detail_diagnostic(
        receipt: saved_receipt_input(saved_receipt),
        receipt_items: input.receipt_items,
        receipt_tax_details: saved_receipt.receipt_tax_details.map do |detail|
          { rate: detail.rate, net_amount: detail.net_amount, amount: detail.amount, description: detail.description }
        end,
        receipt_adjustments: input.receipt_adjustments,
        receipt_payments: input.receipt_payments
      )

      result(**diagnosis)
    end

    private

    attr_reader :receipt

    def saved_receipt_input(receipt)
      {
        total_amount: receipt.total_amount,
        subtotal_amount: receipt.subtotal_amount,
        tax_amount: receipt.tax_amount,
        tax_rate: receipt.tax_rate,
        calculation_settings: receipt.calculation_settings,
        amount_calculation_profile: receipt.amount_calculation_profile,
        amount_total_amount_submitted: false,
        amount_subtotal_amount_submitted: false,
        amount_tax_amount_submitted: false,
        amount_tax_rate_submitted: false
      }.merge(receipt.amount_source_semantics_for_edit.symbolize_keys)
    end

    def result(state:, reason:, applicable:)
      Result.new(state: state, reason: reason, applicable: applicable)
    end
  end
end
