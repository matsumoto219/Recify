# frozen_string_literal: true

module Amounts
  class AdjustmentTotalAggregator
    def initialize(adjustments:, rounding_mode: Amounts::Rounding::TAX_DEFAULT_MODE, receipt_tax_basis: :total_includes_tax)
      @adjustments = Array(adjustments).map { |adjustment| normalize_adjustment(adjustment) }
      @rounding_mode = Amounts::Rounding.normalize_rounding_mode(rounding_mode || Amounts::Rounding::TAX_DEFAULT_MODE)
      @receipt_tax_basis = normalize_receipt_tax_basis(receipt_tax_basis)
    end

    def call
      totals = empty_totals

      adjustments.each do |adjustment|
        amount = adjustment[:amount].to_i
        next unless amount.positive?

        classification = Amounts::AdjustmentClassifier.call(adjustment)

        if classification[:effect] == :payment_adjustment
          totals[:payment_adjustment_total] += signed_amount(adjustment)
          next
        end

        signed = signed_amount(adjustment)
        totals[:receipt_total_delta] += signed

        if signed.positive?
          totals[:surcharge_total] += signed
        else
          totals[:discount_total] += signed.abs
        end

        if uncertain_adjustment?(adjustment)
          totals[:uncertain_adjustments] << adjustment
        end

        rate = normalize_rate(adjustment[:tax_rate])
        if rate.positive?
          totals[:taxable_delta_by_rate][rate] ||= 0
          totals[:taxable_delta_by_rate][rate] += signed

          if signed.positive?
            totals[:taxable_surcharge_total_by_rate][rate] ||= 0
            totals[:taxable_surcharge_total_by_rate][rate] += signed
          else
            totals[:taxable_discount_total_by_rate][rate] ||= 0
            totals[:taxable_discount_total_by_rate][rate] += signed.abs
          end

          apply_taxable_delta!(totals, rate, signed)
        else
          totals[:tax_rate_missing_adjustment_total] += signed.abs
          totals[:subtotal_delta] += signed
          totals[:total_delta] += signed
        end
      end

      totals
    end

    private

    attr_reader :adjustments, :rounding_mode, :receipt_tax_basis

    def empty_totals
      {
        surcharge_total: 0,
        discount_total: 0,
        receipt_total_delta: 0,
        subtotal_delta: 0,
        tax_delta: 0,
        total_delta: 0,
        taxable_surcharge_total_by_rate: {},
        taxable_discount_total_by_rate: {},
        taxable_delta_by_rate: {},
        payment_adjustment_total: 0,
        tax_rate_missing_adjustment_total: 0,
        uncertain_adjustments: []
      }
    end

    def apply_taxable_delta!(totals, rate, signed)
      if receipt_tax_basis == :tax_added_to_subtotal
        tax_delta = signed_tax_from_net(signed, rate)
        totals[:subtotal_delta] += signed
        totals[:tax_delta] += tax_delta
        totals[:total_delta] += signed + tax_delta
      else
        tax_delta = signed_tax_from_gross(signed, rate)
        totals[:subtotal_delta] += signed - tax_delta
        totals[:tax_delta] += tax_delta
        totals[:total_delta] += signed
      end
    end

    def signed_amount(adjustment)
      adjustment[:sign] == "surcharge" ? adjustment[:amount].to_i : -adjustment[:amount].to_i
    end

    def uncertain_adjustment?(adjustment)
      adjustment[:needs_review] == true || (adjustment[:kind] == "other" && adjustment[:source].to_s != "manual")
    end

    def signed_tax_from_net(signed, rate)
      sign = signed.negative? ? -1 : 1
      sign * Amounts::Rounding.apply_rounding(BigDecimal(signed.abs.to_s) * rate, rounding_mode)
    end

    def signed_tax_from_gross(signed, rate)
      sign = signed.negative? ? -1 : 1
      sign * Amounts::Rounding.apply_rounding(BigDecimal(signed.abs.to_s) * rate / (BigDecimal("1") + rate), rounding_mode)
    end

    def normalize_adjustment(adjustment)
      normalized =
        if adjustment.respond_to?(:attributes)
          adjustment.attributes.symbolize_keys
        elsif adjustment.respond_to?(:to_h)
          adjustment.to_h.symbolize_keys
        else
          {}
        end

      kind = ReceiptAdjustment.normalize_kind(normalized[:kind])
      sign = normalized[:sign].to_s

      {
        kind: ReceiptAdjustment::KINDS.include?(kind) ? kind : "other",
        sign: ReceiptAdjustment::SIGNS.include?(sign) ? sign : default_sign_for(kind),
        amount: to_i(normalized[:amount]).abs,
        tax_rate: normalize_rate(normalized[:tax_rate]),
        needs_review: normalized[:needs_review] == true,
        review_reasons: Array(normalized[:review_reasons]).map(&:to_s),
        source: normalized[:source],
        label: normalized[:label],
        source_text: normalized[:source_text]
      }
    end

    def default_sign_for(kind)
      %w[service_charge late_night_charge delivery_fee bag_fee handling_fee].include?(kind.to_s) ? "surcharge" : "discount"
    end

    def normalize_rate(value)
      return BigDecimal("0") if value.nil? || value == ""

      rate = BigDecimal(value.to_s)
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError
      BigDecimal("0")
    end

    def normalize_receipt_tax_basis(value)
      basis = value.to_s.to_sym
      %i[total_includes_tax tax_added_to_subtotal].include?(basis) ? basis : :total_includes_tax
    end

    def to_i(value)
      Amounts::NumberParser.parse_amount(value)
    end
  end
end
