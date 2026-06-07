# frozen_string_literal: true

module Amounts
  class PaymentReconciler
    def initialize(payments:, purchase_total:, payment_adjustment_total:)
      @payments = Array(payments)
      @purchase_total = Amounts::NumberParser.parse_amount(purchase_total)
      @payment_adjustment_total = Amounts::NumberParser.parse_amount(payment_adjustment_total)
    end

    def call
      {
        purchase_total: purchase_total,
        payment_adjustment_total: payment_adjustment_total,
        final_payment_total: final_payment_total,
        payment_amount_sum: payment_amount_sum,
        payment_delta: payment_delta,
        matched: matched?,
        warnings: warnings,
        evidence: evidence
      }
    end

    private

    attr_reader :payments, :purchase_total, :payment_adjustment_total

    def final_payment_total
      @final_payment_total ||= purchase_total + payment_adjustment_total
    end

    def payment_amount_sum
      return nil if payments.blank?

      @payment_amount_sum ||= payments.sum { |payment| Amounts::NumberParser.parse_amount(fetch_value(payment, :amount)) }
    end

    def payment_delta
      return nil if payment_amount_sum.nil?

      payment_amount_sum - final_payment_total
    end

    def matched?
      payment_delta.nil? || payment_delta.zero?
    end

    def warnings
      matched? ? [] : [ :payment_amount_mismatch ]
    end

    def evidence
      return [] if payments.blank?

      [
        {
          source: "receipt_payments",
          payment_amount_sum: payment_amount_sum,
          final_payment_total: final_payment_total,
          payment_delta: payment_delta
        }
      ]
    end

    def fetch_value(object, key)
      if object.respond_to?(:key?)
        return object[key] if object.key?(key)
        return object[key.to_s] if object.key?(key.to_s)
      elsif object.respond_to?(key)
        object.public_send(key)
      end
    end
  end
end
