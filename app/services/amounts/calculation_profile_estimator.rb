# frozen_string_literal: true

module Amounts
  class CalculationProfileEstimator
    ROUNDING_MODES = %i[floor round ceil].freeze
    TAX_BASES = %i[internal external].freeze
    ITEM_BASIS = :tax_included

    def initialize(receipt:, items:, tax_details:, context: :analysis, tax_rounding_modes: nil, discount_rounding_modes: nil, tax_bases: TAX_BASES)
      @receipt = receipt
      @items = Array(items)
      @tax_details = Array(tax_details)
      @context = normalize_context(context)
      @tax_rounding_modes = normalize_rounding_modes(tax_rounding_modes, ROUNDING_MODES)
      @discount_rounding_modes = normalize_rounding_modes(discount_rounding_modes, ROUNDING_MODES)
      @tax_bases = normalize_tax_bases(tax_bases)
    end

    def call
      return empty_result unless @context == :analysis

      candidates = profiles.map { |profile| candidate_for(profile) }
      candidates.sort_by! { |candidate| sort_key(candidate) }

      best = candidates.first

      {
        profile: best&.fetch(:profile, nil),
        score: best&.fetch(:score, nil),
        candidates: candidates
      }
    end

    private

    def profiles
      @tax_rounding_modes.product(@discount_rounding_modes, @tax_bases).map do |tax_rounding_mode, discount_rounding_mode, tax_basis|
        {
          tax_rounding_mode: tax_rounding_mode,
          discount_rounding_mode: discount_rounding_mode,
          tax_basis: tax_basis,
          item_basis: ITEM_BASIS
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
      {
        total: amount_delta(calc[:total], :total_amount),
        subtotal: amount_delta(calc[:subtotal], :subtotal_amount),
        tax: amount_delta(calc[:tax], :tax_amount),
        tax_details: tax_detail_delta(calc, profile),
        item_line_total: item_line_total_delta(calc[:items]),
        discount: discount_delta(profile[:discount_rounding_mode]),
        basis_relation: basis_relation_delta(calc, profile)
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
        tax_basis_penalty(profile[:tax_basis])
    end

    def tax_basis_penalty(tax_basis)
      return 10_000 if tax_basis == :external && !external_tax_candidate_available?

      0
    end

    def sort_key(candidate)
      profile = candidate[:profile]

      [
        candidate[:score],
        tax_basis_priority(profile[:tax_basis]),
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

    def basis_relation_delta(calc, profile)
      case profile[:tax_basis]
      when :external
        (to_i(calc[:item_total]) - to_i(calc[:subtotal])).abs
      else
        (to_i(calc[:item_total]) - to_i(calc[:total])).abs
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

    def external_tax_preferred?
      return false unless external_tax_candidate_available?

      receipt_total = Amounts::NumberParser.parse_amount_or_nil(fetch_value(@receipt, :total_amount))
      return false unless receipt_total&.positive?

      source_item_total == tax_detail_subtotal &&
        receipt_total == tax_detail_subtotal + tax_detail_total
    end

    def source_item_total
      @source_item_total ||= @items.sum do |item|
        line_total = fetch_value(item, :line_total)
        next to_i(line_total) if present?(line_total)

        original_line_total = to_i(fetch_value(item, :original_line_total))
        discount_amount = to_i(fetch_value(item, :discount_amount))
        next [ original_line_total - discount_amount, 0 ].max if original_line_total.positive?

        0
      end
    end

    def tax_detail_subtotal
      @tax_detail_subtotal ||= complete_tax_details.sum { |tax_detail| to_i(fetch_value(tax_detail, :net_amount)) }
    end

    def tax_detail_total
      @tax_detail_total ||= complete_tax_details.sum { |tax_detail| to_i(fetch_value(tax_detail, :amount)) }
    end

    def tax_basis_priority(tax_basis)
      if external_tax_preferred?
        tax_basis == :external ? 0 : 1
      else
        tax_basis == :internal ? 0 : 1
      end
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
        candidates: []
      }
    end
  end
end
