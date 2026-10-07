# frozen_string_literal: true

module Amounts
  class PaymentReviewResult
    PAYMENT_REASONS = %i[payment_amount_mismatch payment_amount_uncertain].freeze

    def self.call(amount_result:, payments:, purchase_total:)
      new(amount_result: amount_result, payments: payments, purchase_total: purchase_total).call
    end

    def initialize(amount_result:, payments:, purchase_total:)
      @result = amount_result.deep_dup
      @payments = Array(payments)
      @purchase_total = purchase_total
    end

    def call
      return result if result.dig(:computed, :purchase_total).nil?

      result[:payment_reconciliation] = reconciliation
      apply_review_result!
      result
    end

    private

    attr_reader :result, :payments, :purchase_total

    def reconciliation
      @reconciliation ||= Amounts::PaymentReconciler.new(
        payments: payments,
        purchase_total: purchase_total,
        payment_adjustment_total: result.dig(:computed, :payment_adjustment_total)
      ).call
    end

    def payment_warnings
      return [] if Amounts::PaymentReconciler.suppress_positive_overpayment?(
        payments: payments,
        payment_delta: reconciliation[:payment_delta],
        final_payment_total: reconciliation[:final_payment_total],
        context: result[:context]
      )

      reconciliation[:warnings]
    end

    def apply_review_result!
      original_reasons = %i[inconsistencies blocking_inconsistencies warning_inconsistencies warning_reasons].flat_map do |key|
        Array(result[key]).map(&:to_sym)
      end
      inconsistencies = (original_reasons - PAYMENT_REASONS) | payment_warnings
      result[:inconsistencies] = inconsistencies
      result[:blocking_inconsistencies] = Amounts::MismatchSeverity.blocking(inconsistencies)
      result[:warning_inconsistencies] = Amounts::MismatchSeverity.warning(inconsistencies)
      result[:warning_reasons] = result[:warning_inconsistencies].map(&:to_s)
      result[:review_reasons] = (Array(result[:review_reasons]) - PAYMENT_REASONS.map(&:to_s)) | payment_warnings.map(&:to_s)
      result[:mismatch_codes] = codes_for(inconsistencies)
      result[:blocking_mismatch_codes] = codes_for(result[:blocking_inconsistencies])
      result[:warning_mismatch_codes] = codes_for(result[:warning_inconsistencies])
      result[:mismatch_messages] = inconsistencies.filter_map do |reason|
        I18n.t("enums.receipt_item.review_reason.#{reason}", default: nil)
      end
      result[:needs_review] = result[:review_reasons].any? || result[:blocking_inconsistencies].any?
      result[:safe_to_auto_complete] = result[:selected_candidate_status] == "accepted" &&
        result.dig(:amount_engine, :no_safe_candidate) == false &&
        !purchase_total.nil? && !result[:needs_review]
    end

    def codes_for(reasons)
      reasons.filter_map { |reason| Amounts::MismatchCodes.code(reason.to_sym) }.uniq
    end
  end
end
