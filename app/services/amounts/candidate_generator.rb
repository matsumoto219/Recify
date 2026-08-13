# frozen_string_literal: true

module Amounts
  class CandidateGenerator
    include Amounts::QuantityUnitResolver

    ROUNDING_MODES = %i[floor round ceil].freeze
    SAME_RATE_MIXED_MAX_ITEMS = 20
    SAME_RATE_MIXED_MAX_STATES = 50_000

    def initialize(receipt:, items:, tax_details:, adjustments:, payments:, context:, tax_rounding_modes:, discount_rounding_modes: nil, tax_excluded_price_conversion_enabled: true)
      @receipt = receipt
      @source_items = Array(items)
      @items = @source_items
      @tax_details = Array(tax_details)
      @adjustments = Array(adjustments)
      @payments = Array(payments)
      @context = context
      @tax_rounding_modes = Array(tax_rounding_modes).presence || ROUNDING_MODES
      @discount_rounding_modes = normalize_rounding_modes(discount_rounding_modes || [ Amounts::Rounding::DISCOUNT_DEFAULT_MODE ])
      @tax_excluded_price_conversion_enabled = tax_excluded_price_conversion_enabled != false
    end

    def call
      discount_rounding_modes.flat_map { |rounding_mode| candidates_for_discount_rounding_mode(rounding_mode) }
    end

    private

    attr_reader :receipt, :source_items, :items, :tax_details, :adjustments, :payments, :context, :tax_rounding_modes, :discount_rounding_modes, :discount_rounding_mode, :tax_excluded_price_conversion_enabled

    def candidates_for_discount_rounding_mode(rounding_mode)
      @discount_rounding_mode = rounding_mode
      @items = normalize_items(rounding_mode)
      reset_item_dependent_cache

      Amounts::CandidateFamilyRegistry.call.flat_map do |family|
        Amounts::CandidateFamilyRegistry.build(family, self)
      end.compact
    end

    def normalize_items(rounding_mode)
      Amounts::ItemTotalAggregator.new(
        items: source_items,
        context: context,
        discount_rounding_mode: rounding_mode
      ).call[:items]
    end

    def reset_item_dependent_cache
      @item_total = nil
      @fallback_tax_rate = nil
    end

    def tax_excluded_price_conversion_enabled?
      return true unless context.to_s.to_sym == :analysis

      tax_excluded_price_conversion_enabled
    end

    def adjusted_item_total
      [ item_total + purchase_adjustment_total, 0 ].max
    end

    def item_tax_rates_missing?
      items.present? && items.all? do |item|
        item = indifferent_hash(item)
        !value_present?(item[:tax_rate])
      end
    end

    def incomplete_tax_detail_amounts_present?
      incomplete_source_tax_details.present?
    end

    def incomplete_source_tax_details
      tax_detail_evidence.incomplete_source_tax_details
    end

    def incomplete_tax_detail_evidence
      Amounts::EvidenceExtractor.incomplete_tax_detail_evidence(incomplete_source_tax_details)
    end

    def calculation_profile(attributes = {})
      { discount_rounding_mode: discount_rounding_mode }.merge(attributes).compact
    end

    def item_projection_calculation_profile(fallback_basis:, attributes: {})
      bases = items.map { |item| item_projection_tax_basis(item, fallback_basis) }.uniq
      return calculation_profile(attributes) unless items.any? { |item| fixed_item_tax_basis?(item) }

      calculation_profile(attributes.merge(item_amount_basis: item_amount_basis_for_tax_bases(bases)))
    end

    def signed_tax_from_net(signed, rate, rounding_mode)
      sign = signed.negative? ? -1 : 1
      sign * Amounts::Rounding.apply_rounding(BigDecimal(signed.abs.to_s) * rate, rounding_mode)
    end

    def signed_tax_from_gross(signed, rate, rounding_mode)
      sign = signed.negative? ? -1 : 1
      sign * rounded_tax_from_gross(signed.abs, rate, rounding_mode)
    end

    def tax_details_from_groups(groups)
      Array(groups).filter_map do |group|
        rate = group[:rate]
        next if rate <= 0

        {
          description: description_for(rate),
          rate: rate,
          net_amount: group[:net],
          amount: group[:tax]
        }
      end
    end

    def description_for(rate)
      percentage = rate * 100
      formatted = percentage.frac.zero? ? percentage.to_i.to_s : percentage.to_s("F")
      profile.tax_rate_target_label(formatted)
    end

    def payment_reconciliation(purchase_total, payment_adjustment_total)
      Amounts::PaymentReconciler.new(
        payments: payments,
        purchase_total: purchase_total,
        payment_adjustment_total: payment_adjustment_total
      ).call
    end

    def payment_warnings(payment)
      warnings = Array(payment[:warnings])
      return warnings unless suppress_positive_overpayment?(payment)

      warnings - [ :payment_amount_mismatch ]
    end

    def payment_evidence(payment)
      Amounts::EvidenceExtractor.payment_evidence(
        payment,
        suppress_positive_overpayment: suppress_positive_overpayment?(payment)
      )
    end

    def suppress_positive_overpayment?(payment)
      Amounts::PaymentReconciler.suppress_positive_overpayment?(
        payments: payments,
        payment_delta: payment[:payment_delta],
        final_payment_total: payment[:final_payment_total],
        context: context
      )
    end

    def purchase_adjustment_total
      @purchase_adjustment_total ||= classified_adjustments.sum do |entry|
        entry[:classification][:effect] == :payment_adjustment ? 0 : entry[:classification][:signed_amount]
      end
    end

    def payment_adjustment_total
      @payment_adjustment_total ||= classified_adjustments.sum do |entry|
        entry[:classification][:effect] == :payment_adjustment ? entry[:classification][:signed_amount] : 0
      end
    end

    def adjustment_warnings
      @adjustment_warnings ||= classified_adjustments.flat_map { |entry| entry[:classification][:warnings] }.uniq
    end

    def adjustment_evidence
      @adjustment_evidence ||= Amounts::EvidenceExtractor.adjustment_evidence(classified_adjustments)
    end

    def classified_adjustments
      @classified_adjustments ||= adjustments.map do |adjustment|
        {
          adjustment: adjustment,
          classification: Amounts::AdjustmentClassifier.call(adjustment)
        }
      end
    end

    def indexed_items_by_rate
      items.each_with_index.group_by { |item, _index| projection_tax_rate_for(item) }
    end

    def detected_tax_details
      tax_detail_evidence.detected_tax_details
    end

    def final_detected_tax_details
      tax_detail_evidence.final_detected_tax_details
    end

    def tax_detail_evidence
      @tax_detail_evidence ||= Amounts::TaxDetailEvidence.new(tax_details)
    end

    def item_with_line_total(item, line_total, normalize_price: false, tax_rate: nil)
      item = indifferent_hash(item)
      normalized = item.merge(line_total: line_total)
      normalized[:tax_rate] = tax_rate unless tax_rate.nil?

      if normalize_price
        price = normalized_unit_price_for(item, line_total)
        normalized[:price] = price unless price.nil?
      end

      normalized
    end

    def item_amount_projection(item, line_total:, rate:, fallback_basis:, rounding_mode:)
      basis = item_projection_tax_basis(item, fallback_basis)
      amounts = amounts_for_tax_basis(line_total, rate, basis, rounding_mode)

      amounts.merge(
        basis: basis,
        basis_source: item_projection_basis_source(item)
      )
    end

    def reference_items_projected_to_gross(rounding_mode:)
      items.map do |item|
        next item unless reference_price_tax_basis(item) == :tax_excluded

        rate = trusted_reference_projection_tax_rate(item)
        return nil if rate.nil?

        amounts = amounts_for_tax_basis(
          item_line_total(item),
          rate,
          :tax_excluded,
          rounding_mode
        )
        item_with_line_total(item, amounts[:gross_amount])
      end
    end

    def grouped_item_amount_projection(item_amounts, rate:, rounding_mode:, rounding_scope:)
      return sum_item_amount_projections(item_amounts) if rounding_scope == :per_item
      return sum_item_amount_projections(item_amounts) if rate <= 0

      item_amounts.group_by { |amounts| amounts.fetch(:basis) }.values
        .map { |partition| rounded_basis_partition(partition, rate, rounding_mode) }
        .then { |partitions| sum_item_amount_projections(partitions) }
    end

    def reference_quantity_price_item?(item)
      indifferent_hash(item)[:pricing_source_kind].to_s == "reference_quantity_price"
    end

    def explicit_line_total_item?(item)
      indifferent_hash(item)[:pricing_source_kind].to_s == "explicit_line_total"
    end

    def fixed_item_tax_basis?(item)
      reference_quantity_price_item?(item) || explicit_line_total_item?(item)
    end

    def item_projection_tax_basis(item, fallback_basis)
      reference_price_tax_basis(item) || (explicit_line_total_item?(item) ? :tax_included : fallback_basis)
    end

    def item_projection_basis_source(item)
      return :reference_price if reference_quantity_price_item?(item)
      return :explicit_line_total if explicit_line_total_item?(item)

      :candidate
    end

    def tax_basis_inference_item?(item)
      !fixed_item_tax_basis?(item)
    end

    def projection_tax_rate_for(item)
      return item_tax_rate(item) unless reference_quantity_price_item?(item)
      return item_tax_rate(item) unless reference_price_tax_basis(item) == :tax_excluded

      trusted_reference_projection_tax_rate(item)
    end

    def reference_projection_tax_rate_missing?
      items.any? do |item|
        reference_quantity_price_item?(item) && projection_tax_rate_for(item).nil?
      end
    end

    def normalize_price_for_tax_basis?(item, basis)
      basis == :tax_excluded && !reference_quantity_price_item?(item)
    end

    def inferred_tax_excluded_assignment?(assignment)
      assignment[:basis] == :tax_excluded && assignment[:basis_source] != :reference_price
    end

    def reference_price_tax_basis(item)
      return nil unless reference_quantity_price_item?(item)

      case indifferent_hash(item)[:reference_price_tax_inclusion].to_s
      when "gross"
        :tax_included
      when "net"
        :tax_excluded
      else
        raise Amounts::ReferenceItemExtension::InvalidSourceError,
          "reference price authority requires an explicit gross or net tax basis"
      end
    end

    def trusted_reference_projection_tax_rate(item)
      item = indifferent_hash(item)
      if value_present?(item[:tax_rate])
        return trusted_explicit_projection_tax_rate(item[:tax_rate])
      end

      trusted_reference_projection_fallback_tax_rate
    end

    def trusted_reference_projection_fallback_tax_rate
      return @trusted_reference_projection_fallback_tax_rate if defined?(@trusted_reference_projection_fallback_tax_rate)

      detail_rates = final_detected_tax_details.map { |detail| detail[:rate] }.uniq
      @trusted_reference_projection_fallback_tax_rate = if detail_rates.one?
        detail_rates.first if tax_detail_evidence.purchase_amount_evidence_present?
      elsif detail_rates.many?
        nil
      elsif value_present?(receipt[:tax_rate])
        trusted_explicit_projection_tax_rate(receipt[:tax_rate])
      end
    end

    def trusted_explicit_projection_tax_rate(value)
      raw = value.to_s.strip
      raw = raw.delete_suffix("%").strip
      return nil unless raw.match?(/\A[+-]?\d+(?:\.\d+)?\z/)

      rate = BigDecimal(raw)
      rate /= 100 if rate > 1
      rate if rate.between?(0, 1)
    rescue ArgumentError
      nil
    end

    def authoritative_reference_item_amount_basis
      taxable_items = items.select do |item|
        item_line_total(item).positive? && item_tax_rate(item).positive?
      end
      return nil if taxable_items.blank?
      return nil unless taxable_items.all? { |item| reference_quantity_price_item?(item) }

      item_amount_basis_for_tax_bases(taxable_items.map { |item| reference_price_tax_basis(item) }.uniq)
    end

    def item_amount_basis_for_tax_bases(bases)
      return :line_total_as_recorded if bases == [ :tax_included ]
      return :line_total_as_net if bases == [ :tax_excluded ]

      :mixed_by_tax_rate_group
    end

    def amounts_for_tax_basis(line_total, rate, basis, rounding_mode)
      if rate <= 0
        return { gross_amount: line_total, net_amount: line_total, tax_amount: 0 }
      end

      if basis == :tax_excluded
        tax = signed_tax_from_net(line_total, rate, rounding_mode)
        { gross_amount: line_total + tax, net_amount: line_total, tax_amount: tax }
      else
        tax = signed_tax_from_gross(line_total, rate, rounding_mode)
        { gross_amount: line_total, net_amount: line_total - tax, tax_amount: tax }
      end
    end

    def rounded_basis_partition(partition, rate, rounding_mode)
      basis = partition.first.fetch(:basis)
      if basis == :tax_excluded
        net = partition.sum { |amounts| amounts[:net_amount] }
        tax = Amounts::Rounding.apply_rounding(BigDecimal(net.to_s) * rate, rounding_mode)
        { gross_amount: net + tax, net_amount: net, tax_amount: tax }
      else
        gross = partition.sum { |amounts| amounts[:gross_amount] }
        tax = rounded_tax_from_gross(gross, rate, rounding_mode)
        { gross_amount: gross, net_amount: gross - tax, tax_amount: tax }
      end
    end

    def sum_item_amount_projections(amounts)
      {
        gross_amount: amounts.sum { |amount| amount[:gross_amount] },
        net_amount: amounts.sum { |amount| amount[:net_amount] },
        tax_amount: amounts.sum { |amount| amount[:tax_amount] }
      }
    end

    def normalized_unit_price_for(item, line_total)
      line_total = to_i(line_total)
      return nil unless line_total.positive?
      return nil if discount_applied?(item)

      quantity = Amounts::NumberParser.parse_quantity(item[:quantity], default: BigDecimal("1"))
      quantity = BigDecimal("1") if quantity <= 0
      return nil unless quantity.frac.zero?
      return nil unless default_or_countable_quantity_unit_for_item?(item)

      quantity_integer = quantity.to_i
      return nil unless quantity_integer.positive?
      return nil unless (line_total % quantity_integer).zero?

      line_total / quantity_integer
    end

    def discount_applied?(item)
      to_i(item[:discount_amount]).positive? || normalize_rate(item[:discount_rate]).positive?
    end

    def item_line_total(item)
      item = indifferent_hash(item)
      return to_i(item[:line_total]) if present?(item[:line_total])
      return 0 unless countable_quantity_unit_for_item?(item)

      price = to_i(item[:price])
      quantity = Amounts::NumberParser.parse_quantity(item[:quantity])
      quantity = BigDecimal("1") if quantity <= 0
      (BigDecimal(price.to_s) * quantity).round(0).to_i
    end

    def item_total
      @item_total ||= items.sum { |item| item_line_total(item) }
    end

    def item_data_present?
      items.any? do |item|
        normalized = indifferent_hash(item)
        next false if unresolved_persisted_authority_free_diagnostic?(normalized)

        item_line_total(normalized).positive? ||
          explicit_zero_amount_item?(normalized) ||
          to_i(normalized[:original_line_total]).positive? ||
          to_i(normalized[:discount_amount]).positive?
      end
    end

    def unresolved_persisted_authority_free_diagnostic?(item)
      return false if item[:pricing_source_kind].present?
      return false unless item[:amount_persisted_item] == true
      return false unless item[:amount_countable_source_changed] == false
      return false unless item[:amount_line_total_changed] == false
      return false unless item[:amount_persisted_line_total].nil?

      %i[
        quantity_unit_raw
        reference_price_amount
        reference_quantity
        reference_quantity_unit_code
        reference_quantity_unit_raw
        reference_price_tax_inclusion
      ].any? { |attribute| !item[attribute].nil? }
    end

    def explicit_zero_amount_item?(item)
      explicit_zero_line_total?(item) || explicit_zero_price_total?(item) || zero_reference_price_item?(item)
    end

    def explicit_zero_line_total?(item)
      value_was_present?(item, :line_total) && to_i(item[:line_total]).zero?
    end

    def explicit_zero_price_total?(item)
      value_was_present?(item, :price) && to_i(item[:price]).zero?
    end

    def zero_reference_price_item?(item)
      reference_quantity_price_item?(item) && present?(item[:line_total]) && to_i(item[:line_total]).zero?
    end

    def value_was_present?(item, key)
      flag = item[:"amount_#{key}_present"]
      return true if flag == true
      return persisted_item_amount_present?(item, key) if flag == false

      present?(item[key])
    end

    def persisted_item_amount_present?(item, key)
      return false unless item[:amount_persisted_item] == true
      return false if key == :line_total && item[:amount_line_total_changed] == true

      value = key == :line_total ? item[:amount_persisted_line_total] : item[key]
      present?(value)
    end

    def item_tax_rate(item)
      normalized = indifferent_hash(item)
      return BigDecimal("0") if non_taxable_item_text?(normalized)

      rate = normalize_rate(normalized[:tax_rate])
      return rate if rate.positive?
      return BigDecimal("0") if value_present?(normalized[:tax_rate]) && rate.zero?

      fallback_tax_rate
    end

    def non_taxable_item_text?(item)
      text = [
        item[:raw_text],
        item[:suggested_name],
        item[:confirmed_name],
        item[:name]
      ].compact.join(" ").unicode_normalize(:nfkc)

      text.match?(profile.analysis_non_taxable_text_pattern)
    end

    def fallback_tax_rate
      @fallback_tax_rate ||= begin
        detail_rates = final_detected_tax_details.map { |detail| detail[:rate] }.uniq
        detail_rates.one? ? detail_rates.first : BigDecimal("0")
      end
    end

    def rounded_tax_from_gross(gross_total, rate, rounding_mode)
      Amounts::Rounding.apply_rounding(BigDecimal(gross_total.to_s) * rate / (BigDecimal("1") + rate), rounding_mode)
    end

    def normalize_rate(value)
      return BigDecimal("0") if value.nil? || value == ""

      rate = BigDecimal(value.to_s.delete("%"))
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError
      BigDecimal("0")
    end

    def normalize_rounding_modes(values)
      Array(values).map { |value| Amounts::Rounding.normalize_rounding_mode(value) }.uniq
    end

    def indifferent_hash(value)
      if value.respond_to?(:with_indifferent_access)
        value.with_indifferent_access
      elsif value.respond_to?(:to_h)
        value.to_h.with_indifferent_access
      else
        {}.with_indifferent_access
      end
    end

    def to_i(value)
      Amounts::NumberParser.parse_amount(value)
    end

    def amount_or_nil(value)
      Amounts::NumberParser.parse_amount_or_nil(value)
    end

    def present?(value)
      !value.nil? && value != ""
    end

    def value_present?(value)
      present?(value)
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
