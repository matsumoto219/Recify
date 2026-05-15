# frozen_string_literal: true

module Amounts
  class CalculationProfileEstimator
    ROUNDING_MODES = %i[floor round ceil].freeze
    TAX_BASES = %i[internal external].freeze
    ITEM_BASES = %i[tax_included tax_excluded mixed].freeze
    ITEM_BASIS = :tax_included
    UNCERTAIN_SCORE_GAP = 100

    def initialize(receipt:, items:, tax_details:, context: :analysis, tax_rounding_modes: nil, discount_rounding_modes: nil, tax_bases: TAX_BASES, item_bases: ITEM_BASES)
      @receipt = receipt
      @items = Array(items)
      @tax_details = Array(tax_details)
      @context = normalize_context(context)
      @tax_rounding_modes = normalize_rounding_modes(tax_rounding_modes, ROUNDING_MODES)
      @discount_rounding_modes = normalize_rounding_modes(discount_rounding_modes, ROUNDING_MODES)
      @tax_bases = normalize_tax_bases(tax_bases)
      @item_bases = normalize_item_bases(item_bases)
    end

    def call
      return empty_result unless @context == :analysis

      candidates = profiles.map { |profile| candidate_for(profile) }
      candidates.sort_by! { |candidate| sort_key(candidate) }

      best = candidates.first

      {
        profile: best&.fetch(:profile, nil),
        score: best&.fetch(:score, nil),
        candidates: candidates,
        warnings: warnings_for(candidates)
      }
    end

    private

    def profiles
      @tax_rounding_modes.product(@discount_rounding_modes, @tax_bases, @item_bases).map do |tax_rounding_mode, discount_rounding_mode, tax_basis, item_basis|
        {
          tax_rounding_mode: tax_rounding_mode,
          discount_rounding_mode: discount_rounding_mode,
          tax_basis: tax_basis,
          item_basis: item_basis
        }
      end
    end

    def candidate_for(profile)
      calc = Amounts::Calculator.new(
        receipt: @receipt,
        items: @items,
        tax_details: @tax_details,
        context: @context,
        tax_rounding_mode: profile[:tax_rounding_mode],
        discount_rounding_mode: profile[:discount_rounding_mode],
        tax_basis: profile[:tax_basis]
      ).call

      deltas = deltas_for(calc, profile)

      {
        profile: profile,
        score: score_for(deltas, profile),
        deltas: deltas
      }
    end

    def deltas_for(calc, profile)
      amounts = profile_amounts(calc, profile)

      {
        total: amount_delta(amounts[:total], :total_amount),
        subtotal: amount_delta(amounts[:subtotal], :subtotal_amount),
        tax: amount_delta(amounts[:tax], :tax_amount),
        tax_details: tax_detail_delta(calc, profile),
        item_line_total: item_line_total_delta(calc[:items]),
        discount: discount_delta(profile[:discount_rounding_mode]),
        basis_relation: basis_relation_delta(calc, profile, amounts)
      }
    end

    def score_for(deltas, profile)
      deltas[:total] * 100 +
        deltas[:tax] * 80 +
        deltas[:subtotal] * 50 +
        deltas[:tax_details] * 80 +
        deltas[:item_line_total] * 40 +
        deltas[:discount] * 40 +
        deltas[:basis_relation] * 100 +
        tax_basis_penalty(profile[:tax_basis]) +
        item_basis_penalty(profile[:item_basis])
    end

    def tax_basis_penalty(tax_basis)
      return 10_000 if tax_basis == :external && !external_tax_candidate_available?

      0
    end

    def item_basis_penalty(item_basis)
      case item_basis
      when :tax_included
        explicit_external_tax_evidence? ? 25 : 0
      when :tax_excluded
        explicit_external_tax_evidence? ? 0 : 25
      when :mixed
        mixed_item_basis_suspected? ? 25 : 1_000
      else
        1_000
      end
    end

    def sort_key(candidate)
      profile = candidate[:profile]

      [
        candidate[:score],
        tax_basis_priority(profile[:tax_basis]),
        item_basis_priority(profile[:item_basis]),
        tax_rounding_priority(profile[:tax_rounding_mode]),
        discount_rounding_priority(profile[:discount_rounding_mode])
      ]
    end

    def amount_delta(computed_value, receipt_key)
      printed_value = Amounts::NumberParser.parse_amount_or_nil(fetch_value(@receipt, receipt_key))
      return 0 if printed_value.nil?

      (to_i(computed_value) - printed_value).abs
    end

    def tax_detail_delta(calc, profile)
      source_groups = tax_details_by_rate(complete_tax_details)
      return 0 if source_groups.blank?

      generated_groups = tax_details_by_rate(generated_tax_details(calc, profile))
      rates = source_groups.keys | generated_groups.keys

      rates.sum do |rate|
        source = source_groups[rate] || { amount: 0, net_amount: 0 }
        generated = generated_groups[rate] || { amount: 0, net_amount: 0 }

        (source[:amount] - generated[:amount]).abs +
          (source[:net_amount] - generated[:net_amount]).abs
      end
    end

    def generated_tax_details(calc, profile)
      if profile[:item_basis] == :tax_excluded
        generated = tax_excluded_tax_details(profile[:tax_rounding_mode])
        return generated if generated.present?
      end

      if calc[:external_tax] || calc[:tax_details_primary]
        return complete_tax_details
      end

      Amounts::TaxDetailAggregator.new(
        items: calc[:items],
        fallback_tax_rate: calc[:tax_rate],
        fallback_net_amount: calc[:subtotal],
        fallback_tax_amount: calc[:tax],
        rounding_mode: profile[:tax_rounding_mode]
      ).call
    end

    def profile_amounts(calc, profile)
      return tax_excluded_amounts(profile[:tax_rounding_mode]) if profile[:item_basis] == :tax_excluded

      {
        subtotal: calc[:subtotal],
        tax: calc[:tax],
        total: calc[:total]
      }
    end

    def tax_excluded_amounts(tax_rounding_mode)
      subtotal = source_item_total
      tax = tax_excluded_tax_details(tax_rounding_mode).sum { |tax_detail| to_i(fetch_value(tax_detail, :amount)) }

      {
        subtotal: subtotal,
        tax: tax,
        total: subtotal + tax
      }
    end

    def tax_excluded_tax_details(tax_rounding_mode)
      groups = @items.each_with_object({}) do |item, hash|
        line_total = source_item_line_total(item)
        next unless line_total.positive?

        rate = normalize_rate(fetch_value(item, :tax_rate))
        rate = fallback_tax_rate if rate <= 0
        next if rate <= 0

        hash[rate] ||= { rate: rate, net_amount: 0, amount: 0 }
        hash[rate][:net_amount] += line_total
        hash[rate][:amount] += Amounts::Rounding.apply_rounding(
          BigDecimal(line_total.to_s) * rate,
          tax_rounding_mode
        )
      end

      groups.values
    end

    def item_line_total_delta(calculated_items)
      Array(calculated_items).each_with_index.sum do |calculated_item, index|
        source_item = @items[index]
        next 0 unless present?(fetch_value(source_item, :line_total))

        (to_i(fetch_value(calculated_item, :line_total)) - to_i(fetch_value(source_item, :line_total))).abs
      end
    end

    def discount_delta(discount_rounding_mode)
      @items.sum do |item|
        original_line_total = to_i(fetch_value(item, :original_line_total))
        discount_amount = to_i(fetch_value(item, :discount_amount))
        discount_rate = normalize_rate(fetch_value(item, :discount_rate))

        next 0 unless original_line_total.positive?
        next 0 unless discount_amount.positive?
        next 0 unless discount_rate.positive?

        estimated_discount = Amounts::Rounding.apply_rounding(
          BigDecimal(original_line_total.to_s) * discount_rate,
          discount_rounding_mode
        )

        (estimated_discount - discount_amount).abs
      end
    end

    def basis_relation_delta(_calc, profile, amounts)
      case profile[:tax_basis]
      when :external
        (source_item_total - to_i(amounts[:subtotal])).abs
      else
        (source_item_total - to_i(amounts[:total])).abs
      end
    end

    def complete_tax_details
      @tax_details.select do |tax_detail|
        normalize_rate(fetch_value(tax_detail, :rate)).positive? &&
          present?(fetch_value(tax_detail, :net_amount)) &&
          present?(fetch_value(tax_detail, :amount))
      end
    end

    def tax_details_by_rate(tax_details)
      tax_details.each_with_object({}) do |tax_detail, groups|
        rate = normalize_rate(fetch_value(tax_detail, :rate))
        next if rate <= 0

        groups[rate] ||= { amount: 0, net_amount: 0 }
        groups[rate][:amount] += to_i(fetch_value(tax_detail, :amount))
        groups[rate][:net_amount] += to_i(fetch_value(tax_detail, :net_amount))
      end
    end

    def external_tax_candidate_available?
      tax_detail_subtotal.positive? && tax_detail_total.positive?
    end

    def explicit_external_tax_evidence?
      @tax_details.any? do |tax_detail|
        fetch_value(tax_detail, :description).to_s.match?(/外税|税別|消費税別|別途消費税/)
      end
    end

    def external_tax_preferred?
      return false unless external_tax_candidate_available?

      receipt_total = Amounts::NumberParser.parse_amount_or_nil(fetch_value(@receipt, :total_amount))
      return false unless receipt_total&.positive?

      source_item_total == tax_detail_subtotal &&
        receipt_total == tax_detail_subtotal + tax_detail_total
    end

    def source_item_total
      @source_item_total ||= @items.sum { |item| source_item_line_total(item) }
    end

    def source_item_line_total(item)
      line_total = fetch_value(item, :line_total)
      return to_i(line_total) if present?(line_total)

      original_line_total = to_i(fetch_value(item, :original_line_total))
      discount_amount = to_i(fetch_value(item, :discount_amount))
      return [ original_line_total - discount_amount, 0 ].max if original_line_total.positive?

      0
    end

    def tax_detail_subtotal
      @tax_detail_subtotal ||= complete_tax_details.sum { |tax_detail| to_i(fetch_value(tax_detail, :net_amount)) }
    end

    def tax_detail_total
      @tax_detail_total ||= complete_tax_details.sum { |tax_detail| to_i(fetch_value(tax_detail, :amount)) }
    end

    def fallback_tax_rate
      tax_detail_rates = complete_tax_details.filter_map do |tax_detail|
        rate = normalize_rate(fetch_value(tax_detail, :rate))
        rate.positive? ? rate : nil
      end.uniq

      return tax_detail_rates.first if tax_detail_rates.one?

      item_rates = @items.filter_map do |item|
        rate = normalize_rate(fetch_value(item, :tax_rate))
        rate.positive? ? rate : nil
      end.uniq

      item_rates.one? ? item_rates.first : BigDecimal("0")
    end

    def tax_basis_priority(tax_basis)
      if external_tax_preferred?
        tax_basis == :external ? 0 : 1
      else
        tax_basis == :internal ? 0 : 1
      end
    end

    def item_basis_priority(item_basis)
      if explicit_external_tax_evidence?
        return { tax_excluded: 0, tax_included: 1, mixed: 2 }.fetch(item_basis, 3)
      end

      return { mixed: 0, tax_included: 1, tax_excluded: 2 }.fetch(item_basis, 3) if mixed_item_basis_suspected?

      { tax_included: 0, tax_excluded: 1, mixed: 2 }.fetch(item_basis, 3)
    end

    def tax_rounding_priority(tax_rounding_mode)
      { floor: 0, round: 1, ceil: 2 }.fetch(tax_rounding_mode, 3)
    end

    def discount_rounding_priority(discount_rounding_mode)
      { round: 0, floor: 1, ceil: 2 }.fetch(discount_rounding_mode, 3)
    end

    def normalize_rounding_modes(values, default)
      modes = values.nil? ? default : Array(values)
      modes.map { |value| Amounts::Rounding.normalize_rounding_mode(value) }.uniq
    end

    def normalize_tax_bases(values)
      Array(values).map { |value| value.to_s.to_sym }.select { |value| TAX_BASES.include?(value) }.presence || TAX_BASES
    end

    def normalize_item_bases(values)
      Array(values).map { |value| value.to_s.to_sym }.select { |value| ITEM_BASES.include?(value) }.presence || ITEM_BASES
    end

    def warnings_for(candidates)
      calculation_profile_uncertain?(candidates) ? [ :calculation_profile_uncertain ] : []
    end

    def calculation_profile_uncertain?(candidates)
      best = candidates.first
      return false unless best
      return false if best[:score].to_i.zero?

      alternative = candidates.find do |candidate|
        basis_changed?(best[:profile], candidate[:profile])
      end
      return false unless alternative

      (alternative[:score].to_i - best[:score].to_i).abs <= UNCERTAIN_SCORE_GAP
    end

    def basis_changed?(left, right)
      left[:item_basis] != right[:item_basis] || left[:tax_basis] != right[:tax_basis]
    end

    def mixed_item_basis_suspected?
      return false unless source_item_total.positive?
      return true if tax_detail_subtotal.positive? && tax_detail_subtotal + tax_detail_total < source_item_total

      rates = @items.map { |item| normalize_rate(fetch_value(item, :tax_rate)) }.uniq
      rates.include?(BigDecimal("0")) && rates.any?(&:positive?)
    end

    def normalize_rate(value)
      return BigDecimal("0") unless present?(value)

      rate = BigDecimal(value.to_s.delete("%"))
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError
      BigDecimal("0")
    end

    def normalize_context(value)
      context = value.to_s.to_sym
      %i[analysis edit_save manual].include?(context) ? context : :analysis
    end

    def fetch_value(object, key)
      if object.respond_to?(:key?)
        return object[key] if object.key?(key)
        object[key.to_s] if object.key?(key.to_s)
      elsif object.respond_to?(:[])
        value = object[key]
        return value unless value.nil?

        string_value = object[key.to_s]
        string_value unless string_value.nil?
      elsif object.respond_to?(key)
        object.public_send(key)
      end
    end

    def to_i(value)
      Amounts::NumberParser.parse_amount(value)
    end

    def present?(value)
      !value.nil? && value != ""
    end

    def empty_result
      {
        profile: nil,
        score: nil,
        candidates: [],
        warnings: []
      }
    end
  end
end
