# frozen_string_literal: true

module Amounts
  class CandidateGenerator
    ROUNDING_MODES = %i[floor round ceil].freeze
    SAME_RATE_MIXED_MAX_ITEMS = 20
    SAME_RATE_MIXED_MAX_STATES = 50_000

    def initialize(receipt:, items:, tax_details:, adjustments:, payments:, context:, tax_rounding_modes:, legacy_result:)
      @receipt = receipt
      @items = Array(items)
      @tax_details = Array(tax_details)
      @adjustments = Array(adjustments)
      @payments = Array(payments)
      @context = context
      @tax_rounding_modes = Array(tax_rounding_modes).presence || ROUNDING_MODES
      @legacy_result = legacy_result || {}
    end

    def call
      [
        legacy_candidate,
        item_candidates,
        printed_tax_detail_candidates,
        mixed_candidates
      ].flatten.compact
    end

    private

    attr_reader :receipt, :items, :tax_details, :adjustments, :payments, :context, :tax_rounding_modes, :legacy_result

    def legacy_candidate
      resolved = indifferent_hash(legacy_result[:resolved])
      computed = indifferent_hash(legacy_result[:computed])
      purchase_total = to_i(resolved[:total] || computed[:total])
      payment = payment_reconciliation(purchase_total, to_i(computed[:payment_adjustment_total]))

      Amounts::Candidate.new(
        candidate_id: "legacy_resolver",
        basis: "legacy_resolver",
        subtotal: to_i(resolved[:subtotal] || computed[:subtotal]),
        tax: to_i(resolved[:tax] || computed[:tax]),
        purchase_total: purchase_total,
        final_payment_total: payment[:final_payment_total],
        purchase_adjustment_total: to_i(computed[:adjustment_surcharge_total]) - to_i(computed[:adjustment_discount_total]),
        payment_adjustment_total: to_i(computed[:payment_adjustment_total]),
        payment_amount_sum: payment[:payment_amount_sum],
        tax_details: Array(legacy_result[:tax_details]),
        tax_rate_groups: [],
        rounding_mode: legacy_result.dig(:rounding_mode, :tax),
        rounding_scope: :per_tax_rate_group,
        warnings: Array(legacy_result[:warning_inconsistencies]),
        evidence: payment[:evidence] + [ { source: "legacy_receipt_amount_service", purchase_total: purchase_total } ],
        computed_items: Array(computed[:items]),
        calculation_profile: legacy_result[:calculation_profile],
        source: :legacy
      )
    end

    def item_candidates
      tax_rounding_modes.flat_map do |rounding_mode|
        Amounts::RoundingScope::SCOPES.flat_map do |rounding_scope|
          [
            items_as_tax_included_candidate(rounding_mode, rounding_scope),
            items_as_tax_excluded_candidate(rounding_mode, rounding_scope)
          ]
        end
      end
    end

    def items_as_tax_included_candidate(rounding_mode, rounding_scope)
      build_item_candidate(
        candidate_id: "items_as_tax_included/#{rounding_mode}/#{rounding_scope}",
        basis: "items_as_tax_included",
        item_basis: :tax_included,
        rounding_mode: rounding_mode,
        rounding_scope: rounding_scope
      )
    end

    def items_as_tax_excluded_candidate(rounding_mode, rounding_scope)
      build_item_candidate(
        candidate_id: "items_as_tax_excluded/#{rounding_mode}/#{rounding_scope}",
        basis: "items_as_tax_excluded",
        item_basis: :tax_excluded,
        rounding_mode: rounding_mode,
        rounding_scope: rounding_scope
      )
    end

    def build_item_candidate(candidate_id:, basis:, item_basis:, rounding_mode:, rounding_scope:)
      groups = empty_groups
      computed_items = []

      items.each_with_index do |item, index|
        line_total = item_line_total(item)
        rate = item_tax_rate(item)
        group = groups[rate]

        amounts = item_basis_amounts(line_total, rate, item_basis, rounding_mode)
        group[:item_amounts] << amounts
        computed_items[index] = item_with_line_total(item, amounts[:gross_amount])
      end

      apply_purchase_adjustments_to_groups!(groups, item_basis: item_basis, rounding_mode: rounding_mode)
      tax_rate_groups = build_tax_rate_groups(groups, rounding_mode, rounding_scope, item_basis: item_basis)
      purchase_total = tax_rate_groups.sum { |group| group[:gross] }
      tax = tax_rate_groups.sum { |group| group[:tax] }
      payment = payment_reconciliation(purchase_total, payment_adjustment_total)
      warnings = adjustment_warnings

      Amounts::Candidate.new(
        candidate_id: candidate_id,
        basis: basis,
        subtotal: purchase_total - tax,
        tax: tax,
        purchase_total: purchase_total,
        final_payment_total: payment[:final_payment_total],
        purchase_adjustment_total: purchase_adjustment_total,
        payment_adjustment_total: payment_adjustment_total,
        payment_amount_sum: payment[:payment_amount_sum],
        tax_details: tax_details_from_groups(tax_rate_groups),
        tax_rate_groups: tax_rate_groups,
        rounding_mode: rounding_mode,
        rounding_scope: rounding_scope,
        warnings: warnings,
        evidence: adjustment_evidence + payment[:evidence] + [ { source: "receipt_items", formula: basis, purchase_total: purchase_total } ],
        computed_items: computed_items,
        source: :amount_engine
      )
    end

    def printed_tax_detail_candidates
      return [] if detected_tax_details.blank?

      tax_rounding_modes.flat_map do |rounding_mode|
        [
          printed_tax_details_candidate(
            candidate_id: "printed_tax_details_gross/#{rounding_mode}",
            basis: "printed_tax_details_gross",
            amount_basis: :gross,
            rounding_mode: rounding_mode
          ),
          printed_tax_details_candidate(
            candidate_id: "printed_tax_details_net/#{rounding_mode}",
            basis: "printed_tax_details_net",
            amount_basis: :net,
            rounding_mode: rounding_mode
          ),
          printed_tax_details_candidate(
            candidate_id: "external_tax_from_receipt/#{rounding_mode}",
            basis: "external_tax_from_receipt",
            amount_basis: :detected,
            rounding_mode: rounding_mode
          ),
          raw_printed_tax_details_candidate(rounding_mode)
        ]
      end
    end

    def printed_tax_details_candidate(candidate_id:, basis:, amount_basis:, rounding_mode:)
      groups = final_detected_tax_details.each_with_object({}) do |detail, hash|
        rate = detail[:rate]
        next unless rate.positive?

        amounts = tax_detail_amounts_for(detail, amount_basis)
        hash[rate] ||= { rate: rate, gross: 0, net: 0, tax: 0 }
        hash[rate][:gross] += amounts[:gross]
        hash[rate][:net] += amounts[:net]
        hash[rate][:tax] += amounts[:tax]
      end

      non_taxable_item_total = items.select { |item| item_tax_rate(item).zero? }.sum { |item| item_line_total(item) }
      if non_taxable_item_total.positive?
        groups[BigDecimal("0")] ||= { rate: BigDecimal("0"), gross: 0, net: 0, tax: 0 }
        groups[BigDecimal("0")][:gross] += non_taxable_item_total
        groups[BigDecimal("0")][:net] += non_taxable_item_total
      end

      purchase_total = groups.values.sum { |group| group[:gross] } + purchase_adjustment_total
      tax = groups.values.sum { |group| group[:tax] }
      payment = payment_reconciliation(purchase_total, payment_adjustment_total)

      Amounts::Candidate.new(
        candidate_id: candidate_id,
        basis: basis,
        subtotal: purchase_total - tax,
        tax: tax,
        purchase_total: purchase_total,
        final_payment_total: payment[:final_payment_total],
        purchase_adjustment_total: purchase_adjustment_total,
        payment_adjustment_total: payment_adjustment_total,
        payment_amount_sum: payment[:payment_amount_sum],
        tax_details: tax_details_from_groups(groups.values),
        tax_rate_groups: groups.values,
        rounding_mode: rounding_mode,
        rounding_scope: :per_tax_rate_group,
        warnings: adjustment_warnings,
        evidence: final_detected_tax_details.map { |detail| detail[:evidence] } + adjustment_evidence + payment[:evidence],
        computed_items: items,
        source: :amount_engine
      )
    end

    def raw_printed_tax_details_candidate(rounding_mode)
      groups = detected_tax_details.each_with_object({}) do |detail, hash|
        rate = detail[:rate]
        next unless rate.positive?
        next unless detail[:net_amount].to_i.positive? && detail[:amount].to_i.positive?

        hash[rate] ||= { rate: rate, gross: 0, net: 0, tax: 0 }
        hash[rate][:net] += detail[:net_amount].to_i
        hash[rate][:tax] += detail[:amount].to_i
        hash[rate][:gross] += detail[:net_amount].to_i + detail[:amount].to_i
      end

      purchase_total = groups.values.sum { |group| group[:gross] }
      payment = payment_reconciliation(purchase_total, payment_adjustment_total)

      Amounts::Candidate.new(
        candidate_id: "printed_tax_details_raw_sum/#{rounding_mode}",
        basis: "printed_tax_details_raw_sum",
        subtotal: purchase_total - groups.values.sum { |group| group[:tax] },
        tax: groups.values.sum { |group| group[:tax] },
        purchase_total: purchase_total,
        final_payment_total: payment[:final_payment_total],
        purchase_adjustment_total: 0,
        payment_adjustment_total: payment_adjustment_total,
        payment_amount_sum: payment[:payment_amount_sum],
        tax_details: tax_details_from_groups(groups.values),
        tax_rate_groups: groups.values,
        rounding_mode: rounding_mode,
        rounding_scope: :per_tax_rate_group,
        warnings: [ :tax_detail_mismatch ],
        evidence: detected_tax_details.map { |detail| detail[:evidence] } + payment[:evidence],
        computed_items: items,
        source: :amount_engine
      )
    end

    def mixed_candidates
      return [] unless final_detected_tax_details.present?

      tax_rounding_modes.map do |rounding_mode|
        mixed_candidate(rounding_mode)
      end.compact
    end

    def mixed_candidate(rounding_mode)
      targets = tax_detail_targets_by_rate
      return nil if targets.blank?

      computed_items = Array.new(items.size)
      groups = {}
      warnings = adjustment_warnings.dup
      exact = true
      evidence = final_detected_tax_details.map { |detail| detail[:evidence] }

      indexed_items_by_rate.each do |rate, indexed_items|
        if rate.zero?
          gross = indexed_items.sum { |item, _index| item_line_total(item) }
          groups[rate] = { rate: rate, gross: gross, net: gross, tax: 0 }
          indexed_items.each { |item, index| computed_items[index] = item_with_line_total(item, item_line_total(item)) }
          next
        end

        target = targets[rate]
        unless target
          exact = false
          warnings << :item_tax_rate_group_uncertain
          indexed_items.each { |item, index| computed_items[index] = item_with_line_total(item, item_line_total(item)) }
          next
        end

        assignment = item_level_assignment_for(indexed_items, target, rate, rounding_mode)
        unless assignment[:status] == :exact
          exact = false
          warnings << :price_tax_inclusion_uncertain
          indexed_items.each { |item, index| computed_items[index] = item_with_line_total(item, item_line_total(item)) }
          groups[rate] = target.slice(:rate, :gross, :net, :tax)
          next
        end

        groups[rate] = {
          rate: rate,
          gross: assignment[:gross],
          net: assignment[:net],
          tax: assignment[:tax]
        }
        assignment[:assignments].each do |entry|
          computed_items[entry[:index]] = item_with_line_total(items[entry[:index]], entry[:gross_amount])
        end
        warnings << :price_tax_inclusion_uncertain if assignment[:assignments].any? { |entry| entry[:basis] == :tax_excluded }
        evidence.concat(assignment[:assignments].map { |entry| entry.slice(:source, :index, :basis, :rate, :net_amount, :tax_amount, :gross_amount) })
      end

      targets.each do |rate, target|
        next if groups.key?(rate)

        groups[rate] = target.slice(:rate, :gross, :net, :tax)
      end

      purchase_total = groups.values.sum { |group| group[:gross] } + purchase_adjustment_total
      tax = groups.values.sum { |group| group[:tax] }
      payment = payment_reconciliation(purchase_total, payment_adjustment_total)

      Amounts::Candidate.new(
        candidate_id: "mixed_by_tax_rate_group/#{rounding_mode}",
        basis: "mixed_by_tax_rate_group",
        subtotal: purchase_total - tax,
        tax: tax,
        purchase_total: purchase_total,
        final_payment_total: payment[:final_payment_total],
        purchase_adjustment_total: purchase_adjustment_total,
        payment_adjustment_total: payment_adjustment_total,
        payment_amount_sum: payment[:payment_amount_sum],
        tax_details: tax_details_from_groups(groups.values),
        tax_rate_groups: groups.values,
        rounding_mode: rounding_mode,
        rounding_scope: :per_tax_rate_group,
        warnings: warnings.uniq,
        hard_reject_reasons: exact ? [] : [ :tax_detail_mismatch ],
        evidence: evidence + adjustment_evidence + payment[:evidence] + [ { source: "amount_engine", formula: "mixed_by_tax_rate_group", purchase_total: purchase_total } ],
        computed_items: computed_items.map.with_index { |item, index| item || item_with_line_total(items[index], item_line_total(items[index])) },
        source: :amount_engine
      )
    end

    def item_level_assignment_for(indexed_items, target, rate, rounding_mode)
      return { status: :search_limited, assignments: [] } if indexed_items.size > SAME_RATE_MIXED_MAX_ITEMS

      states = { [ 0, 0, 0 ] => [ [] ] }
      indexed_items.each do |item, index|
        candidates = item_level_basis_candidates(item, index, rate, rounding_mode)
        next_states = {}

        states.each do |(net_sum, tax_sum, gross_sum), paths|
          candidates.each do |candidate|
            next_key = [
              net_sum + candidate[:net_amount],
              tax_sum + candidate[:tax_amount],
              gross_sum + candidate[:gross_amount]
            ]
            next if next_key[0] > target[:net] || next_key[1] > target[:tax] || next_key[2] > target[:gross]

            next_states[next_key] ||= []
            paths.each do |path|
              next_states[next_key] << (path + [ candidate ])
              next_states[next_key] = next_states[next_key].first(2)
            end
          end
        end

        return { status: :search_limited, assignments: [] } if next_states.size > SAME_RATE_MIXED_MAX_STATES
        return { status: :no_exact, assignments: [] } if next_states.blank?

        states = next_states
      end

      matches = states[[ target[:net], target[:tax], target[:gross] ]] || []
      return { status: :ambiguous, assignments: [] } if matches.many?
      return { status: :no_exact, assignments: [] } if matches.blank?

      {
        status: :exact,
        assignments: matches.first,
        net: target[:net],
        tax: target[:tax],
        gross: target[:gross]
      }
    end

    def item_level_basis_candidates(item, index, rate, rounding_mode)
      line_total = item_line_total(item)
      return [] unless line_total.positive?

      included_tax = rounded_tax_from_gross(line_total, rate, rounding_mode)
      excluded_tax = Amounts::Rounding.apply_rounding(BigDecimal(line_total.to_s) * rate, rounding_mode)

      [
        {
          source: "receipt_items",
          index: index,
          rate: rate,
          basis: :tax_included,
          net_amount: line_total - included_tax,
          tax_amount: included_tax,
          gross_amount: line_total
        },
        {
          source: "receipt_items",
          index: index,
          rate: rate,
          basis: :tax_excluded,
          net_amount: line_total,
          tax_amount: excluded_tax,
          gross_amount: line_total + excluded_tax
        }
      ]
    end

    def item_basis_amounts(line_total, rate, item_basis, rounding_mode)
      return { gross_amount: line_total, net_amount: line_total, tax_amount: 0 } if rate <= 0

      case item_basis
      when :tax_excluded
        tax = Amounts::Rounding.apply_rounding(BigDecimal(line_total.to_s) * rate, rounding_mode)
        { gross_amount: line_total + tax, net_amount: line_total, tax_amount: tax }
      else
        tax = rounded_tax_from_gross(line_total, rate, rounding_mode)
        { gross_amount: line_total, net_amount: line_total - tax, tax_amount: tax }
      end
    end

    def build_tax_rate_groups(groups, rounding_mode, rounding_scope, item_basis:)
      groups.values.map do |group|
        rate = group[:rate]
        if rate <= 0
          gross = group[:item_amounts].sum { |amounts| amounts[:gross_amount] }
          next { rate: rate, gross: gross, net: gross, tax: 0 }
        end

        gross, net, tax = rounded_group_amounts(group[:item_amounts], rate, rounding_mode, rounding_scope, item_basis: item_basis)
        { rate: rate, gross: gross, net: net, tax: tax }
      end
    end

    def rounded_group_amounts(amounts, rate, rounding_mode, rounding_scope, item_basis:)
      case rounding_scope
      when :per_item
        gross = amounts.sum { |amount| amount[:gross_amount] }
        tax = amounts.sum { |amount| amount[:tax_amount] }
        [ gross, gross - tax, tax ]
      else
        if item_basis == :tax_excluded
          net = amounts.sum { |amount| amount[:net_amount] }
          tax = Amounts::Rounding.apply_rounding(BigDecimal(net.to_s) * rate, rounding_mode)
          [ net + tax, net, tax ]
        else
          gross = amounts.sum { |amount| amount[:gross_amount] }
          tax = rounded_tax_from_gross(gross, rate, rounding_mode)
          [ gross, gross - tax, tax ]
        end
      end
    end

    def apply_purchase_adjustments_to_groups!(groups, item_basis:, rounding_mode:)
      classified_adjustments.each do |entry|
        classification = entry[:classification]
        next if classification[:effect] == :payment_adjustment

        rate = classification[:tax_rate]
        groups[rate] ||= { rate: rate, item_amounts: [] }
        amount = classification[:signed_amount]
        groups[rate][:item_amounts] << if item_basis == :tax_excluded && rate.positive?
          tax = signed_tax_from_net(amount, rate, rounding_mode)
          { gross_amount: amount + tax, net_amount: amount, tax_amount: tax }
        else
          tax = rate.positive? ? signed_tax_from_gross(amount, rate, rounding_mode) : 0
          { gross_amount: amount, net_amount: amount - tax, tax_amount: tax }
        end
      end
    end

    def signed_tax_from_net(signed, rate, rounding_mode)
      sign = signed.negative? ? -1 : 1
      sign * Amounts::Rounding.apply_rounding(BigDecimal(signed.abs.to_s) * rate, rounding_mode)
    end

    def signed_tax_from_gross(signed, rate, rounding_mode)
      sign = signed.negative? ? -1 : 1
      sign * rounded_tax_from_gross(signed.abs, rate, rounding_mode)
    end

    def tax_detail_targets_by_rate
      final_detected_tax_details.each_with_object({}) do |detail, hash|
        rate = detail[:rate]
        next unless rate.positive?

        hash[rate] ||= { rate: rate, gross: 0, net: 0, tax: 0 }
        hash[rate][:gross] += detail[:target_gross_amount].to_i
        hash[rate][:net] += detail[:target_net_amount].to_i
        hash[rate][:tax] += detail[:amount].to_i
      end
    end

    def tax_detail_amounts_for(detail, amount_basis)
      basis = amount_basis == :detected ? detail[:basis] : amount_basis
      case basis
      when :gross
        tax = detail[:amount].to_i
        gross = detail[:net_amount].to_i
        { gross: gross, net: [ gross - tax, 0 ].max, tax: tax }
      else
        net = detail[:net_amount].to_i
        tax = detail[:amount].to_i
        { gross: net + tax, net: net, tax: tax }
      end
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
      "#{formatted}%対象"
    end

    def payment_reconciliation(purchase_total, payment_adjustment_total)
      Amounts::PaymentReconciler.new(
        payments: payments,
        purchase_total: purchase_total,
        payment_adjustment_total: payment_adjustment_total
      ).call
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
      @adjustment_evidence ||= classified_adjustments.map { |entry| entry[:classification][:evidence] }
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
      items.each_with_index.group_by { |item, _index| item_tax_rate(item) }
    end

    def detected_tax_details
      @detected_tax_details ||= Amounts::TaxDetailBasisDetector.call(tax_details)
    end

    def final_detected_tax_details
      @final_detected_tax_details ||= detected_tax_details.select do |detail|
        %i[gross net].include?(detail[:basis]) &&
          detail[:rate].positive? &&
          detail[:net_amount].to_i.positive? &&
          detail[:amount].to_i.positive?
      end
    end

    def empty_groups
      Hash.new do |hash, rate|
        hash[rate] = { rate: rate, item_amounts: [] }
      end
    end

    def item_with_line_total(item, line_total)
      indifferent_hash(item).merge(line_total: line_total)
    end

    def item_line_total(item)
      item = indifferent_hash(item)
      return to_i(item[:line_total]) if present?(item[:line_total])
      return 0 unless countable_quantity_unit?(item[:quantity_unit])

      price = to_i(item[:price])
      quantity = Amounts::NumberParser.parse_quantity(item[:quantity])
      quantity = BigDecimal("1") if quantity <= 0
      (BigDecimal(price.to_s) * quantity).round(0).to_i
    end

    def item_tax_rate(item)
      rate = normalize_rate(indifferent_hash(item)[:tax_rate])
      return rate if rate.positive?

      fallback_tax_rate
    end

    def fallback_tax_rate
      @fallback_tax_rate ||= begin
        detail_rates = final_detected_tax_details.map { |detail| detail[:rate] }.uniq
        detail_rates.one? ? detail_rates.first : BigDecimal("0")
      end
    end

    def countable_quantity_unit?(unit)
      return true unless defined?(ReceiptItem::COUNTABLE_QUANTITY_UNITS)

      ReceiptItem::COUNTABLE_QUANTITY_UNITS.include?(unit.to_s.strip)
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

    def present?(value)
      !value.nil? && value != ""
    end
  end
end
