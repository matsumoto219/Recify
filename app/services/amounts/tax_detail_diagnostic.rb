# frozen_string_literal: true

module Amounts
  class TaxDetailDiagnostic
    REQUIRED_SETTINGS = %w[tax_rounding_mode discount_rounding_mode tax_rounding_scope].freeze
    TAX_DETAIL_MISMATCHES = %i[tax_detail_mismatch tax_detail_rate_mismatch].freeze
    UNCOMPARABLE_WARNINGS = %i[tax_detail_incomplete tax_detail_partial price_tax_inclusion_uncertain adjustment_tax_rate_missing].freeze

    def initialize(receipt:, receipt_items:, receipt_tax_details:, receipt_adjustments:, receipt_payments:)
      @receipt = receipt
      @items = Array(receipt_items)
      @tax_details = Array(receipt_tax_details)
      @adjustments = Array(receipt_adjustments)
      @payments = Array(receipt_payments)
    end

    def call
      return diagnosis(:unavailable, :not_applicable, applicable: false) if tax_details.empty?
      return diagnosis(:unavailable, :incomplete_tax_details) unless complete_tax_details?

      settings = effective_calculation_settings
      return diagnosis(:unavailable, @settings_reason) unless settings
      item_reason = item_comparison_reason
      return diagnosis(:unavailable, item_reason) if item_reason
      if purchase_adjustments_present? && settings.value_for("purchase_adjustment_tax_inclusion").nil?
        return diagnosis(:unavailable, :missing_purchase_adjustment_tax_inclusion)
      end

      calculation_receipt = receipt.to_h.merge(calculation_settings: settings.to_h)
      result = yield(calculation_receipt)
      classify(result)
    end

    private

    attr_reader :receipt, :items, :tax_details, :adjustments, :payments

    def complete_tax_details?
      evidence = tax_detail_evidence
      detected = evidence.detected_tax_details
      return false unless evidence.purchase_amount_evidence_present?

      detected.present? && detected.all? do |detail|
        %i[gross net].include?(detail[:basis]) &&
          detail[:rate].positive? && detail[:net_amount].to_i.positive? && detail[:amount].to_i.positive?
      end
    end

    def effective_calculation_settings
      saved = source_value(receipt, :calculation_settings)
      settings = ReceiptCalculationSettings.parse(saved) unless saved.nil?
      if !saved.nil? && !settings
        @settings_reason = :invalid_calculation_settings
        return nil
      end

      missing = REQUIRED_SETTINGS.reject { |key| settings&.value_for(key) }
      if purchase_adjustments_present? && !settings&.value_for("purchase_adjustment_tax_inclusion")
        missing << "purchase_adjustment_tax_inclusion"
      end
      return settings if missing.empty?

      historical = historical_settings
      unless historical
        @settings_reason ||= missing == [ "purchase_adjustment_tax_inclusion" ] ? :missing_purchase_adjustment_tax_inclusion : :missing_calculation_settings
        return nil
      end

      attributes = settings&.to_h || { "schema_version" => ReceiptCalculationSettings::SCHEMA_VERSION }
      if attributes.any? do |key, entry|
        key != "schema_version" && historical[key] && entry["value"] != historical[key]
      end
        @settings_reason = :conflicting_calculation_settings
        return nil
      end

      missing.each do |key|
        value = historical[key]
        unless value
          @settings_reason = key == "purchase_adjustment_tax_inclusion" ? :missing_purchase_adjustment_tax_inclusion : :missing_calculation_settings
          return nil
        end

        attributes[key] = { "value" => value, "origin" => "legacy_record" }
      end

      ReceiptCalculationSettings.parse(attributes).tap do |recovered|
        @settings_reason = :invalid_calculation_settings unless recovered
      end
    end

    def historical_settings
      snapshot = source_value(receipt, :amount_calculation_profile)
      @settings_reason = :invalid_calculation_profile unless snapshot.nil?
      return nil unless snapshot.is_a?(Hash) && snapshot["schema_version"] == 1
      return nil unless snapshot["selected_candidate_status"] == "accepted"

      engine = snapshot["amount_engine"]
      return nil unless engine.is_a?(Hash) && engine["schema_version"] == 1
      return nil unless engine["selected_candidate_status"] == "accepted" && engine["no_safe_candidate"] == false

      candidate = engine["selected_candidate"]
      return nil unless candidate.is_a?(Hash) && candidate["hard_reject_reasons"] == []
      return nil unless candidate["candidate_id"] == engine["selected_candidate_id"]
      return nil unless candidate["basis"] == engine["selected_basis"]
      return nil unless %w[items_as_tax_included items_as_tax_excluded].include?(candidate["basis"])

      candidate_mode = candidate["rounding_mode"]
      candidate_scope = candidate["rounding_scope"]
      return nil unless ReceiptCalculationSettings::ROUNDING_MODES.include?(candidate_mode)
      return nil unless ReceiptCalculationSettings::ROUNDING_SCOPES.include?(candidate_scope)

      profile = snapshot["profile"]
      profile = {} unless profile.is_a?(Hash)
      rounding = snapshot["rounding_mode"]
      rounding = {} unless rounding.is_a?(Hash)
      return nil if profile["tax_rounding_mode"] && rounding["tax"] && profile["tax_rounding_mode"] != rounding["tax"]
      if profile["discount_rounding_mode"] && rounding["discount"] && profile["discount_rounding_mode"] != rounding["discount"]
        return nil
      end
      profile_mode = profile["tax_rounding_mode"] || rounding["tax"]
      return nil if profile_mode && profile_mode != candidate_mode

      discount_mode = profile["discount_rounding_mode"] || rounding["discount"]
      return nil unless ReceiptCalculationSettings::ROUNDING_MODES.include?(discount_mode)

      {
        "tax_rounding_mode" => candidate_mode,
        "discount_rounding_mode" => discount_mode,
        "tax_rounding_scope" => candidate_scope
      }
    end

    def item_comparison_reason
      items.each do |item|
        kind = source_value(item, :pricing_source_kind)
        return :missing_item_pricing_source if kind.nil?
        return :invalid_item_pricing_source unless %w[count_unit_price explicit_line_total reference_quantity_price].include?(kind)

        basis_key = kind == "reference_quantity_price" ? :reference_price_tax_inclusion : :input_tax_inclusion
        basis = source_value(item, basis_key)
        return :missing_item_tax_inclusion if basis.nil?
        return :invalid_item_tax_inclusion unless %w[gross net].include?(basis)

        rate = source_value(item, :tax_rate)
        return :missing_item_tax_rate if rate.nil? || rate == ""

        rate_value = rate.is_a?(BigDecimal) ? rate.to_s("F") : rate
        return :invalid_item_tax_rate unless tax_detail_evidence.trusted_explicit_projection_rate(rate_value)
      end

      nil
    end

    def tax_detail_evidence
      @tax_detail_evidence ||= Amounts::TaxDetailEvidence.new(tax_details)
    end

    def purchase_adjustments_present?
      adjustments.any? do |adjustment|
        classification = Amounts::AdjustmentClassifier.call(adjustment)
        classification[:effect] != :payment_adjustment && classification[:signed_amount].nonzero?
      end
    end

    def classify(result)
      engine = result[:amount_engine] || {}
      selected = engine[:selected_candidate]
      return diagnosis(:unavailable, :no_comparable_candidate) unless selected
      return diagnosis(:unavailable, :no_comparable_candidate) unless %w[items_as_tax_included items_as_tax_excluded].include?(selected[:basis])

      warnings = (Array(result[:inconsistencies]) + Array(selected[:warnings])).map(&:to_sym)
      return diagnosis(:unavailable, :incomplete_tax_details) if warnings.intersect?(%i[tax_detail_incomplete tax_detail_partial])
      return diagnosis(:unavailable, :tax_detail_comparison_unavailable) if warnings.intersect?(UNCOMPARABLE_WARNINGS)
      return diagnosis(:unavailable, :no_comparable_candidate) unless engine[:no_safe_candidate] == false && selected[:hard_reject_reasons] == []
      return diagnosis(:unavailable, :tax_detail_comparison_unavailable) unless comparable_result?(result)

      mismatch = warnings.find { |warning| TAX_DETAIL_MISMATCHES.include?(warning) }
      return diagnosis(:mismatch, mismatch) if mismatch
      return diagnosis(:mismatch, :tax_detail_mismatch) unless tax_details_match_result?(result)

      diagnosis(:consistent, nil)
    end

    def tax_details_match_result?(result)
      source_groups = tax_detail_evidence.targets_by_rate.transform_values { |detail| detail.slice(:net, :tax) }
      generated_groups = Array(result[:tax_details]).each_with_object({}) do |detail, groups|
        rate = source_value(detail, :rate)
        next unless rate.respond_to?(:positive?) && rate.positive?

        groups[rate] ||= { net: 0, tax: 0 }
        groups[rate][:net] += source_value(detail, :net_amount)
        groups[rate][:tax] += source_value(detail, :amount)
      end

      generated_groups == source_groups
    end

    def comparable_result?(result)
      generated = Array(result[:tax_details])
      return false if generated.empty?

      positive_rate_details = generated.select do |detail|
        rate = source_value(detail, :rate)
        rate.respond_to?(:positive?) && rate.positive?
      end
      return false if positive_rate_details.empty?

      positive_rate_details.all? do |detail|
        amount = source_value(detail, :amount)
        net_amount = source_value(detail, :net_amount)
        amount.respond_to?(:positive?) && amount.positive? &&
          net_amount.respond_to?(:positive?) && net_amount.positive?
      end
    end

    def source_value(source, key)
      return source[key] if source.respond_to?(:key?) && source.key?(key)

      source[key.to_s] if source.respond_to?(:key?) && source.key?(key.to_s)
    end

    def diagnosis(state, reason, applicable: true)
      { state: state, reason: reason, applicable: applicable }
    end
  end
end
