# frozen_string_literal: true

module Amounts
  class CandidateScorer
    def initialize(receipt:, payments:, tax_details: [], context: :analysis)
      @receipt = receipt
      @payments = Array(payments)
      @tax_details = Array(tax_details)
      @context = context.to_s.to_sym
    end

    def call(candidate)
      breakdown = score_breakdown(candidate)
      candidate.with_score(
        score: breakdown.values.sum,
        score_breakdown: breakdown
      )
    end

    private

    attr_reader :receipt, :payments, :tax_details, :context

    def score_breakdown(candidate)
      {
        receipt_total_delta: receipt_total_delta(candidate) * 100,
        receipt_subtotal_delta: amount_delta(candidate.subtotal, :subtotal_amount, candidate: candidate) * 30,
        receipt_tax_delta: amount_delta(candidate.tax, :tax_amount, candidate: candidate) * 60,
        payment_delta: payment_delta(candidate) * 120,
        receipt_input_item_delta: receipt_input_item_delta(candidate) * 1_000,
        warning_penalty: warning_penalty(candidate),
        hard_reject_penalty: candidate.rejected? ? 1_000_000 : 0,
        rounding_mode_penalty: rounding_mode_penalty(candidate),
        external_tax_exact_tax_bonus: external_tax_exact_tax_bonus(candidate),
        basis_penalty: basis_penalty(candidate)
      }
    end

    def receipt_total_delta(candidate)
      return 0 if stale_receipt_amounts_ignored?(candidate)

      printed = Amounts::NumberParser.parse_amount_or_nil(fetch_value(receipt, :total_amount))
      return 0 if printed.nil?
      return 0 if gross_tax_detail_candidate?(candidate) &&
        receipt_subtotal_matches_purchase_total?(candidate) &&
        !net_tax_details_match_receipt_amounts?

      (candidate.purchase_total.to_i - printed).abs
    end

    def amount_delta(computed_value, receipt_key, candidate:)
      return 0 if stale_receipt_amounts_ignored?(candidate)
      return 0 if inconsistent_subtotal_or_tax_ignored?(receipt_key, candidate)

      printed = Amounts::NumberParser.parse_amount_or_nil(fetch_value(receipt, receipt_key))
      return 0 if printed.nil?

      (computed_value.to_i - printed).abs
    end

    def payment_delta(candidate)
      # 編集後の支払行は購入金額の根拠ではなく、候補確定後の照合証跡として扱う。
      return 0 if context == :edit_save
      return 0 if payments.blank? || candidate.payment_amount_sum.nil?

      delta = candidate.payment_amount_sum.to_i - candidate.final_payment_total.to_i
      return 0 if Amounts::PaymentReconciler.suppress_positive_overpayment?(
        payments: payments,
        payment_delta: delta,
        final_payment_total: candidate.final_payment_total,
        context: context
      )

      delta.abs
    end

    def basis_penalty(candidate)
      case candidate.basis.to_s
      when "mixed_by_tax_rate_group"
        mixed_candidate_basis_penalty(candidate)
      when "external_tax_from_receipt"
        net_tax_detail_candidate_supported?(candidate) || external_tax_evidence? ? 0 : 3
      when "printed_tax_details_gross"
        gross_tax_detail_candidate_supported?(candidate) ? gross_tax_detail_basis_penalty : 5_000
      when "printed_tax_details_net"
        net_tax_detail_candidate_supported?(candidate) ? net_tax_detail_basis_penalty(candidate) : 5_000
      when "items_as_tax_included"
        empty_item_candidate_with_tax_details?(candidate) ? 5_000 : (external_tax_evidence? ? 12 : 0)
      when "items_as_tax_excluded"
        empty_item_candidate_with_tax_details?(candidate) ? 5_000 : (external_tax_evidence? ? 0 : 2_000)
      when "receipt_input_preserved"
        -1
      else
        25
      end
    end

    def mixed_candidate_basis_penalty(candidate)
      if mixed_candidate_receipt_amounts_match?(candidate) &&
          !external_tax_evidence? &&
          mixed_candidate_tax_excluded_items_normalized?(candidate)
        return -2
      end

      mixed_candidate_receipt_amounts_match?(candidate) ? 0 : (external_tax_evidence? ? 15 : 0)
    end

    def receipt_input_item_delta(candidate)
      return 0 unless candidate.basis.to_s == "receipt_input_preserved"
      return 0 if receipt_input_conflict_candidate_payment_matches?(candidate)

      evidence = candidate.evidence.find do |entry|
        entry.respond_to?(:[]) && entry[:source].to_s == "receipt_input"
      end
      Amounts::NumberParser.parse_amount(evidence&.[](:item_delta))
    end

    def receipt_input_conflict_candidate_payment_matches?(candidate)
      return false unless candidate.warnings.map(&:to_sym).include?(:tax_detail_mismatch)
      return false unless candidate.payment_amount_sum.present?

      candidate.payment_amount_sum.to_i == candidate.final_payment_total.to_i
    end

    def external_tax_exact_tax_bonus(candidate)
      return 0 unless context == :analysis
      return 0 unless external_tax_evidence?
      return 0 unless external_tax_exact_tax_candidate?(candidate)
      return 0 unless receipt_subtotal_matches_subtotal?(candidate)
      return 0 unless receipt_tax_matches_tax?(candidate)
      return 0 if receipt_total_matches_purchase_total?(candidate)
      return 0 if Array(candidate.warnings).map(&:to_sym).include?(:price_tax_inclusion_uncertain)

      -100
    end

    def external_tax_exact_tax_candidate?(candidate)
      %w[
        external_tax_from_receipt
        items_as_tax_excluded
        printed_tax_details_net
      ].include?(candidate.basis.to_s) &&
        candidate.purchase_total.to_i == candidate.subtotal.to_i + candidate.tax.to_i
    end

    def stale_receipt_amounts_ignored?(candidate)
      manual_or_edit_context? &&
        item_derived_candidate?(candidate) &&
        item_total(candidate).positive?
    end

    def manual_or_edit_context?
      %i[manual edit_save].include?(context)
    end

    def item_derived_candidate?(candidate)
      %w[
        items_as_tax_included
        items_as_tax_excluded
        mixed_by_tax_rate_group
      ].include?(candidate.basis.to_s)
    end

    def warning_penalty(candidate)
      blocking = Amounts::MismatchSeverity.blocking(candidate.warnings).size * 50_000
      tax_detail_rate = candidate.warnings.include?(:tax_detail_rate_mismatch) ? 500 : 0
      price_tax_inclusion = candidate.warnings.include?(:price_tax_inclusion_uncertain) ? 10 : 0

      blocking + tax_detail_rate + price_tax_inclusion
    end

    def rounding_mode_penalty(candidate)
      { floor: 0, round: 100, ceil: 200 }.fetch(candidate.rounding_mode, 300)
    end

    def gross_tax_detail_candidate_supported?(candidate)
      gross_tax_detail_candidate?(candidate) &&
        detected_tax_details.present? &&
        detected_tax_details.all? { |detail| detail[:basis] == :gross } &&
        (
          receipt_total_matches_purchase_total?(candidate) ||
            receipt_subtotal_matches_purchase_total?(candidate) ||
            adjusted_item_total(candidate) == candidate.purchase_total.to_i
        )
    end

    def net_tax_detail_candidate_supported?(candidate)
      return true if net_tax_details_match_receipt_amounts?

      detected_tax_details.present? &&
        detected_tax_details.all? { |detail| detail[:basis] == :net } &&
        (
          receipt_total_matches_purchase_total?(candidate) ||
            adjusted_item_total(candidate) == candidate.subtotal.to_i ||
            item_total(candidate) == candidate.subtotal.to_i ||
            item_total(candidate) == candidate.purchase_total.to_i
        )
    end

    def net_tax_detail_basis_penalty(candidate)
      return -1 if candidate.warnings.map(&:to_sym) == [ :price_tax_inclusion_uncertain ] &&
        receipt_total_matches_purchase_total?(candidate) &&
        receipt_tax_matches_tax?(candidate)

      item_total(candidate) == candidate.purchase_total.to_i ? -1 : 2
    end

    def gross_tax_detail_basis_penalty
      duplicate_or_intermediate_tax_details? ? 0 : -1
    end

    def duplicate_or_intermediate_tax_details?
      detected_tax_details.any? { |detail| detail[:basis] == :intermediate } ||
        detected_tax_details.group_by { |detail| detail[:rate] }.any? do |rate, details|
          rate.positive? && details.count { |detail| detail[:net_amount].to_i.positive? && detail[:amount].to_i.positive? } > 1
        end
    end

    def gross_tax_detail_candidate?(candidate)
      candidate.basis.to_s == "printed_tax_details_gross" ||
        candidate.calculation_profile&.[](:tax_detail_amount_basis).to_s == "gross"
    end

    def receipt_total_matches_purchase_total?(candidate)
      total = Amounts::NumberParser.parse_amount_or_nil(fetch_value(receipt, :total_amount))
      !total.nil? && total == candidate.purchase_total.to_i
    end

    def receipt_subtotal_matches_purchase_total?(candidate)
      subtotal = Amounts::NumberParser.parse_amount_or_nil(fetch_value(receipt, :subtotal_amount))
      !subtotal.nil? && subtotal == candidate.purchase_total.to_i
    end

    def receipt_subtotal_matches_subtotal?(candidate)
      subtotal = Amounts::NumberParser.parse_amount_or_nil(fetch_value(receipt, :subtotal_amount))
      !subtotal.nil? && subtotal == candidate.subtotal.to_i
    end

    def receipt_tax_matches_tax?(candidate)
      tax = Amounts::NumberParser.parse_amount_or_nil(fetch_value(receipt, :tax_amount))
      !tax.nil? && tax == candidate.tax.to_i
    end

    def mixed_candidate_receipt_amounts_match?(candidate)
      receipt_total_matches_purchase_total?(candidate) &&
        receipt_subtotal_matches_subtotal?(candidate) &&
        receipt_tax_matches_tax?(candidate)
    end

    def mixed_candidate_tax_excluded_items_normalized?(candidate)
      Array(candidate.computed_items).any? do |item|
        line_total = Amounts::NumberParser.parse_amount_or_nil(fetch_value(item, :line_total))
        original_line_total = Amounts::NumberParser.parse_amount_or_nil(fetch_value(item, :original_line_total))

        line_total.present? &&
          original_line_total.present? &&
          line_total > original_line_total &&
          positive_tax_rate?(fetch_value(item, :tax_rate))
      end
    end

    def positive_tax_rate?(value)
      return false if value.nil? || value == ""

      BigDecimal(value.to_s).positive?
    rescue ArgumentError
      false
    end

    def net_tax_details_match_receipt_amounts?
      return false unless receipt_subtotal_tax_total_consistent?
      return false if detected_tax_details.blank?

      detected_tax_details.sum { |detail| detail[:net_amount].to_i } == receipt_amount(:subtotal_amount) &&
        detected_tax_details.sum { |detail| detail[:amount].to_i } == receipt_amount(:tax_amount)
    end

    def receipt_subtotal_tax_total_consistent?
      subtotal = receipt_amount(:subtotal_amount)
      tax = receipt_amount(:tax_amount)
      total = receipt_amount(:total_amount)

      !subtotal.nil? && !tax.nil? && !total.nil? && subtotal + tax == total
    end

    def inconsistent_subtotal_or_tax_ignored?(receipt_key, candidate)
      return false unless context == :analysis
      return false unless %i[subtotal_amount tax_amount].include?(receipt_key)

      subtotal = receipt_amount(:subtotal_amount)
      tax = receipt_amount(:tax_amount)
      total = receipt_amount(:total_amount)
      return false if subtotal.nil? || tax.nil? || total.nil?
      return false unless candidate.purchase_total.to_i == total

      subtotal + tax != total
    end

    def receipt_amount(key)
      Amounts::NumberParser.parse_amount_or_nil(fetch_value(receipt, key))
    end

    def adjusted_item_total(candidate)
      [ item_total(candidate) + candidate.purchase_adjustment_total.to_i, 0 ].max
    end

    def item_total(candidate)
      Array(candidate.computed_items).sum do |item|
        Amounts::NumberParser.parse_amount(fetch_value(item, :line_total))
      end
    end

    def empty_item_candidate_with_tax_details?(candidate)
      detected_tax_details.present? && item_total(candidate).zero?
    end

    def external_tax_evidence?
      return true if tax_details.any? { |detail| fetch_value(detail, :description).to_s.match?(profile.analysis_external_tax_description_pattern) }

      subtotal = Amounts::NumberParser.parse_amount_or_nil(fetch_value(receipt, :subtotal_amount))
      tax = Amounts::NumberParser.parse_amount_or_nil(fetch_value(receipt, :tax_amount))
      total = Amounts::NumberParser.parse_amount_or_nil(fetch_value(receipt, :total_amount))

      subtotal.present? &&
        tax.present? &&
        total.present? &&
        subtotal + tax == total &&
        detected_tax_details.present? &&
        detected_tax_details.all? { |detail| detail[:basis] == :net }
    end

    def detected_tax_details
      @detected_tax_details ||= Amounts::TaxDetailBasisDetector.call(tax_details).select do |detail|
        detail[:rate].positive? && detail[:amount].to_i.positive? && detail[:net_amount].to_i.positive?
      end
    end

    def fetch_value(object, key)
      if object.respond_to?(:key?)
        return object[key] if object.key?(key)
        object[key.to_s] if object.key?(key.to_s)
      elsif object.respond_to?(key)
        object.public_send(key)
      end
    end

    def profile
      ReceiptAnalysisProfiles.default
    end
  end
end
