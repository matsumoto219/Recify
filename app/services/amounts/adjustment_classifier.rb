# frozen_string_literal: true

module Amounts
  class AdjustmentClassifier
    PAYMENT_ADJUSTMENT_KINDS = %w[point_usage].freeze
    PURCHASE_DISCOUNT_KINDS = %w[receipt_discount coupon return_refund].freeze
    SURCHARGE_KINDS = %w[service_charge late_night_charge delivery_fee bag_fee handling_fee].freeze

    class << self
      def call(adjustment)
        new(adjustment).call
      end

      def payment_adjustment?(adjustment)
        call(adjustment)[:effect] == :payment_adjustment
      end

      def purchase_affecting?(adjustment)
        effect = call(adjustment)[:effect]
        effect != :payment_adjustment
      end
    end

    def initialize(adjustment)
      @adjustment = normalize_adjustment(adjustment)
    end

    def call
      {
        effect: effect,
        signed_amount: signed_amount,
        tax_treatment: tax_treatment,
        taxable: tax_rate.positive?,
        tax_rate: tax_rate,
        warnings: warnings,
        evidence: evidence
      }
    end

    private

    attr_reader :adjustment

    def effect
      return :payment_adjustment if payment_adjustment_kind? || cashless_payment_adjustment?
      return :unknown_adjustment if adjustment[:kind] == "other" && adjustment[:source].to_s != "manual"

      :purchase_adjustment
    end

    def tax_treatment
      return :not_applicable if effect == :payment_adjustment
      return :unknown if effect == :unknown_adjustment
      return :taxable if tax_rate.positive?

      :non_taxable
    end

    def payment_adjustment_kind?
      PAYMENT_ADJUSTMENT_KINDS.include?(adjustment[:kind].to_s)
    end

    def cashless_payment_adjustment?
      text = [
        adjustment[:kind],
        adjustment[:label],
        adjustment[:source_text]
      ].compact.join(" ")

      text.match?(profile.analysis_cashless_reward_adjustment_pattern)
    end

    def purchase_known?
      PURCHASE_DISCOUNT_KINDS.include?(adjustment[:kind].to_s) ||
        SURCHARGE_KINDS.include?(adjustment[:kind].to_s)
    end

    def warnings
      results = []
      results << :adjustment_uncertain if uncertain?
      results << :adjustment_tax_rate_missing if effect != :payment_adjustment && purchase_known? && tax_rate.zero? && signed_amount.nonzero?
      results
    end

    def uncertain?
      return false if payment_adjustment_kind? || cashless_payment_adjustment?

      adjustment[:needs_review] == true ||
        (adjustment[:kind] == "other" && adjustment[:source].to_s != "manual")
    end

    def evidence
      {
        source: "receipt_adjustment",
        kind: adjustment[:kind],
        sign: adjustment[:sign],
        amount: adjustment[:amount],
        effect: effect,
        tax_treatment: tax_treatment,
        tax_rate: tax_rate
      }
    end

    def signed_amount
      adjustment[:sign] == "surcharge" ? adjustment[:amount].to_i : -adjustment[:amount].to_i
    end

    def tax_rate
      @tax_rate ||= normalize_rate(adjustment[:tax_rate])
    end

    def normalize_adjustment(value)
      normalized =
        if value.respond_to?(:attributes)
          value.attributes.symbolize_keys
        elsif value.respond_to?(:to_h)
          value.to_h.symbolize_keys
        else
          {}
        end

      kind = ReceiptAdjustment.normalize_kind(normalized[:kind])
      sign = normalized[:sign].to_s

      {
        kind: defined?(ReceiptAdjustment::KINDS) && ReceiptAdjustment::KINDS.include?(kind) ? kind : "other",
        sign: defined?(ReceiptAdjustment::SIGNS) && ReceiptAdjustment::SIGNS.include?(sign) ? sign : default_sign_for(kind),
        amount: Amounts::NumberParser.parse_amount(normalized[:amount]).abs,
        tax_rate: normalized[:tax_rate],
        needs_review: normalized[:needs_review] == true,
        source: normalized[:source],
        label: normalized[:label],
        source_text: normalized[:source_text]
      }
    end

    def default_sign_for(kind)
      if defined?(ReceiptAdjustment::SURCHARGE_KINDS) && ReceiptAdjustment::SURCHARGE_KINDS.include?(kind.to_s)
        "surcharge"
      else
        "discount"
      end
    end

    def normalize_rate(value)
      return BigDecimal("0") if value.nil? || value == ""

      rate = BigDecimal(value.to_s.delete("%"))
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError
      BigDecimal("0")
    end

    def profile
      ReceiptAnalysisProfiles.default
    end
  end
end
