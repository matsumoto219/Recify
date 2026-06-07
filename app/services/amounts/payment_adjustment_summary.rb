# frozen_string_literal: true

module Amounts
  class PaymentAdjustmentSummary
    Summary = Struct.new(:payment_adjustment_total, :final_payment_total, keyword_init: true)

    def self.call(receipt:, receipt_adjustments: nil)
      new(receipt: receipt, receipt_adjustments: receipt_adjustments).call
    end

    def initialize(receipt:, receipt_adjustments: nil)
      @receipt = receipt
      @receipt_adjustments = receipt_adjustments
    end

    def call
      profile_summary = summary_from_profile
      return profile_summary if profile_summary

      summary_from_adjustments
    end

    private

    attr_reader :receipt, :receipt_adjustments

    def summary_from_profile
      profile = fetch_value(receipt, :amount_calculation_profile)
      return nil unless profile.respond_to?(:key?)

      payment_adjustment_total = first_nonzero_amount(
        fetch_nested(profile, :computed, :payment_adjustment_total),
        fetch_nested(profile, :amount_engine, :selected_candidate, :payment_adjustment_total)
      )
      # 支払調整がない場合、UIでは購入合計と実支払額が同じなので実支払額欄を出さない。
      return nil if payment_adjustment_total.nil?

      final_payment_total = first_present_amount(
        fetch_nested(profile, :computed, :final_payment_total),
        fetch_nested(profile, :amount_engine, :selected_candidate, :final_payment_total)
      )
      final_payment_total ||= receipt_total_amount&.+(payment_adjustment_total)
      return nil if final_payment_total.nil?

      Summary.new(
        payment_adjustment_total: payment_adjustment_total,
        final_payment_total: final_payment_total
      )
    end

    def summary_from_adjustments
      payment_adjustment_total = adjustments.sum do |adjustment|
        classification = Amounts::AdjustmentClassifier.call(adjustment)
        classification[:effect] == :payment_adjustment ? classification[:signed_amount].to_i : 0
      end
      # 支払調整がない場合、UIでは購入合計と実支払額が同じなので実支払額欄を出さない。
      return nil unless payment_adjustment_total.nonzero?

      total = receipt_total_amount
      return nil if total.nil?

      Summary.new(
        payment_adjustment_total: payment_adjustment_total,
        final_payment_total: total + payment_adjustment_total
      )
    end

    def adjustments
      return Array(receipt_adjustments) unless receipt_adjustments.nil?

      value = fetch_value(receipt, :receipt_adjustments)
      value.respond_to?(:to_a) ? value.to_a : []
    end

    def receipt_total_amount
      @receipt_total_amount ||= Amounts::NumberParser.parse_amount_or_nil(fetch_value(receipt, :total_amount))
    end

    def first_present_amount(*values)
      values.each do |value|
        amount = Amounts::NumberParser.parse_amount_or_nil(value)
        return amount unless amount.nil?
      end

      nil
    end

    def first_nonzero_amount(*values)
      values.each do |value|
        amount = Amounts::NumberParser.parse_amount_or_nil(value)
        return amount if amount&.nonzero?
      end

      nil
    end

    def fetch_nested(object, *keys)
      keys.reduce(object) do |current, key|
        return nil if current.nil?

        fetch_value(current, key)
      end
    end

    def fetch_value(object, key)
      if object.respond_to?(:key?)
        return object[key] if object.key?(key)
        return object[key.to_s] if object.key?(key.to_s)
      end

      object.public_send(key) if object.respond_to?(key)
    end
  end
end
