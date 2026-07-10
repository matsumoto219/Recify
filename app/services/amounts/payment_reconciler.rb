# frozen_string_literal: true

module Amounts
  class PaymentReconciler
    CASH_TENDERED_PAYMENT_PATTERN = /
      \A\s*cash\s*\z|
      \bcash(?:\s+(?:payment|paid|tendered|received))?\b|
      \b(?:paid\s+)?cash\b|
      \btendered\b|
      \bamount\s+received\b|
      \breceived\b
    /ix.freeze

    class << self
      def suppress_positive_overpayment?(payments:, payment_delta:, final_payment_total:, context:)
        return false unless context.to_s.to_sym == :analysis

        delta = Amounts::NumberParser.parse_amount_or_nil(payment_delta)
        return false unless delta&.positive?

        normalized_payments = Array(payments)
        return false if exact_final_payment_line_present?(normalized_payments, final_payment_total)
        return false unless normalized_payments.one?

        cash_tendered_like_payment?(normalized_payments.first)
      end

      private

      def exact_final_payment_line_present?(payments, final_payment_total)
        total = Amounts::NumberParser.parse_amount_or_nil(final_payment_total)
        return false if total.nil?

        Array(payments).many? do |payment|
          Amounts::NumberParser.parse_amount_or_nil(fetch_value(payment, :amount)) == total
        end
      end

      def cash_tendered_like_payment?(payment)
        text = payment_text(payment)

        text.match?(CASH_TENDERED_PAYMENT_PATTERN) || profile_cash_tendered_like_payment?(text)
      end

      def profile_cash_tendered_like_payment?(text)
        profile = ReceiptAnalysisProfiles.default
        return false unless profile.respond_to?(:analysis_cash_tendered_payment_pattern)

        pattern = profile.analysis_cash_tendered_payment_pattern
        pattern.present? && text.match?(pattern)
      end

      def payment_text(payment)
        %i[method label source_text text].filter_map do |key|
          value = fetch_value(payment, key)
          value if value.present?
        end.join(" ").unicode_normalize(:nfkc).downcase.tr("_-", " ")
      end

      def fetch_value(object, key)
        if object.respond_to?(:key?)
          return object[key] if object.key?(key)
          object[key.to_s] if object.key?(key.to_s)
        elsif object.respond_to?(key)
          object.public_send(key)
        end
      end
    end

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
        reconciliation_status: reconciliation_status,
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
      return true if reconciliation_status == :matched
      return false if %i[mismatched evidence_missing].include?(reconciliation_status)

      nil
    end

    def reconciliation_status
      return payment_adjustment_total.zero? ? :not_observed : :evidence_missing if payments.blank?

      payment_delta.zero? ? :matched : :mismatched
    end

    def warnings
      # 支払不足・過払いは計算候補の破綻ではなく、保存後にユーザーへ確認を促すreview対象として扱う。
      return [] if %i[matched not_observed].include?(reconciliation_status)

      [ :payment_amount_mismatch ]
    end

    def evidence
      if payments.blank?
        return [] if payment_adjustment_total.zero?

        return [
          {
            source: "receipt_payments",
            payment_amount_sum: nil,
            final_payment_total: final_payment_total,
            payment_delta: nil,
            payment_evidence_missing: true
          }
        ]
      end

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
        object[key.to_s] if object.key?(key.to_s)
      elsif object.respond_to?(key)
        object.public_send(key)
      end
    end
  end
end
