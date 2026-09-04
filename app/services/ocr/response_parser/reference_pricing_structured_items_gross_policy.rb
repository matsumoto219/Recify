class Ocr::ResponseParser::ReferencePricingStructuredItemsGrossPolicy
  CONTRACT_VERSION = "reference_pricing_structured_items_gross_policy_v1"
  EVIDENCE_KIND = "structured_items_receipt_inner_tax_summary"
  MEMBER_EVIDENCE_KIND = "structured_items_receipt_inner_tax_summary_member"
  SOURCE_PROVIDER = "azure_structured"
  TAX_INCLUSION = "gross"
  ELIGIBLE_REASON = "eligible"
  REASONS = %w[
    eligible
    amount_limit_invalid
    candidate_invalid
    receipt_scope_invalid
    conflict_present
    evidence_invalid
    projection_invalid
    amount_mismatch
  ].freeze
  EXACT_DECIMAL_PATTERN = /\A(?:0|[1-9]\d*)(?:\.\d+)?\z/.freeze
  CANDIDATE_ID_PATTERN = /\Aazure_items_(?<item_index>0|[1-9]\d*)_reference_pricing\z/.freeze
  COMPONENT_NAMES = %i[reference_price reference_quantity purchased_quantity printed_line_total].freeze
  COMPONENT_FIELD_NAMES = {
    reference_price: "Price",
    purchased_quantity: "Quantity",
    printed_line_total: "TotalPrice"
  }.freeze
  MAX_ITEMS = Ocr::ResponseParser::ReferencePricingStructuredItemsGrossEvidenceExtractor::MAX_ITEMS
  MAX_NUMBER_BYTES = 64
  MAX_AMOUNT = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_AMOUNT
  MAX_PROVIDER_SPAN = Ocr::ResponseParser::MAX_REFERENCE_PRICING_PROVIDER_SPAN
  MAX_LINES = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_LINES

  Result = Data.define(
    :eligible,
    :reason,
    :reference_price_tax_inclusion,
    :evidence_kind,
    :member_evidence_kind,
    :candidate_ids,
    :candidate_members,
    :contract_version
  ) do
    def initialize(
      eligible:,
      reason:,
      reference_price_tax_inclusion: nil,
      evidence_kind: nil,
      candidate_ids: [],
      candidate_members: []
    )
      super(
        eligible: eligible == true,
        reason: reason.to_s.dup.freeze,
        reference_price_tax_inclusion: reference_price_tax_inclusion&.dup&.freeze,
        evidence_kind: evidence_kind&.dup&.freeze,
        member_evidence_kind: MEMBER_EVIDENCE_KIND.dup.freeze,
        candidate_ids: candidate_ids.map { |candidate_id| candidate_id.dup.freeze }.freeze,
        candidate_members: candidate_members.map { |member| member.deep_dup.freeze }.freeze,
        contract_version: CONTRACT_VERSION.dup.freeze
      )
    end

    def eligible?
      eligible == true
    end
  end

  class << self
    def call(
      candidates:,
      item_count:,
      retained_item_indexes:,
      summary_gross_evidence:,
      adjustment_count:,
      discount_count:,
      item_line_total_limit:
    )
      return result("amount_limit_invalid") unless valid_amount_limit?(item_line_total_limit)
      return result("receipt_scope_invalid") unless exact_receipt_scope?(
        item_count:,
        retained_item_indexes:
      )
      return result("conflict_present") unless adjustment_count == 0 && discount_count == 0

      evidence = exact_evidence(summary_gross_evidence, item_count:, maximum: item_line_total_limit)
      return result("evidence_invalid") if evidence.nil?

      candidate_entries = exact_candidates(candidates, evidence:, maximum: item_line_total_limit)
      return result("candidate_invalid") if candidate_entries.nil?
      return result("projection_invalid") unless candidate_entries.all? do |entry|
        entry.fetch(:projection).is_a?(Hash)
      end
      return result("amount_mismatch") unless candidate_entries.all? do |entry|
        candidate_amounts_match?(entry, evidence:, maximum: item_line_total_limit)
      end

      result(
        ELIGIBLE_REASON,
        eligible: true,
        reference_price_tax_inclusion: TAX_INCLUSION,
        evidence_kind: EVIDENCE_KIND,
        candidate_ids: candidate_entries.map { |entry| entry.fetch(:candidate).fetch(:candidate_id) },
        candidate_members: candidate_entries.map do |entry|
          candidate = entry.fetch(:candidate)
          { candidate_id: candidate.fetch(:candidate_id), item_index: candidate.fetch(:item_index) }
        end
      )
    rescue EncodingError, ArgumentError, KeyError, NoMethodError, TypeError
      result("candidate_invalid")
    end

    private

    def exact_receipt_scope?(item_count:, retained_item_indexes:)
      return false unless item_count.is_a?(Integer) && item_count.between?(2, MAX_ITEMS)

      retained_item_indexes == (0...item_count).to_a
    end

    def exact_candidates(candidates, evidence:, maximum:)
      candidates = Array(candidates)
      return unless candidates.size.between?(2, evidence_value(evidence, :item_parents).size)

      entries = candidates.map do |candidate|
        metadata = exact_candidate(candidate, evidence:, maximum:)
        return if metadata.nil?

        metadata
      end.sort_by { |entry| entry.fetch(:candidate).fetch(:item_index) }
      indexes = entries.map { |entry| entry.fetch(:candidate).fetch(:item_index) }
      return unless indexes.uniq == indexes

      entries.freeze
    end

    def exact_candidate(candidate, evidence:, maximum:)
      return unless candidate.is_a?(Hash)

      item_index = candidate[:item_index]
      return unless item_index.is_a?(Integer) && item_index.between?(0, MAX_ITEMS - 1)
      match = CANDIDATE_ID_PATTERN.match(candidate[:candidate_id].to_s)
      return if match.nil? || Integer(match[:item_index], 10) != item_index
      return unless candidate[:source_kind].nil?
      return unless candidate[:validation_state] == "ambiguous"
      return unless candidate[:rejection_reasons] == [ "ambiguous_tax_inclusion" ]
      return unless candidate[:reference_price_tax_inclusion] == "unknown"
      return unless candidate[:tax_inclusion_evidence].nil?

      parent = evidence_value(evidence, :item_parents).fetch(item_index)
      return unless parent_index(parent, :item_index) == item_index

      COMPONENT_NAMES.each do |component_name|
        return unless valid_component?(
          candidate[component_name],
          component_name:,
          item_index:,
          parent:,
          maximum:
        )
      end

      reference_quantity = candidate[:reference_quantity]
      purchased_quantity = candidate[:purchased_quantity]
      return unless reference_quantity[:unit_status] == "known"
      return unless purchased_quantity[:unit_status] == "known"
      return unless %w[explicit implicit_per_unit].include?(reference_quantity[:origin])
      if reference_quantity[:origin] == "implicit_per_unit"
        return unless exact_decimal(reference_quantity[:amount], maximum:) == BigDecimal("1")
      end
      return unless ReceiptQuantityUnit.convertible?(
        from: purchased_quantity[:unit_code],
        to: reference_quantity[:unit_code]
      )

      {
        candidate:,
        projection: reference_projection(candidate, maximum:)
      }.freeze
    end

    def valid_component?(component, component_name:, item_index:, parent:, maximum:)
      return false unless component.is_a?(Hash)
      return false if exact_decimal(component[:amount], maximum:).nil?

      evidence = component[:evidence]
      return false unless evidence.is_a?(Hash)
      return false unless evidence[:source_provider] == SOURCE_PROVIDER
      return false unless evidence[:item_index] == item_index

      field_names = if component_name == :reference_quantity
        reference_quantity_field_names(component, maximum:)
      else
        [ COMPONENT_FIELD_NAMES.fetch(component_name) ]
      end
      return false unless field_names.any? do |field_name|
        evidence[:source_field_path] == "documents[0].fields.Items[#{item_index}].#{field_name}"
      end

      evidence_within_parent?(evidence, parent)
    end

    def reference_quantity_field_names(component, maximum:)
      return [ "Price" ] if component[:origin] == "explicit"
      return [] unless component[:origin] == "implicit_per_unit"
      return [] unless exact_decimal(component[:amount], maximum:) == BigDecimal("1")

      %w[Price Quantity QuantityUnit]
    end

    def exact_evidence(value, item_count:, maximum:)
      evidence = if value.is_a?(
        Ocr::ResponseParser::ReferencePricingStructuredItemsGrossEvidenceExtractor::Result
      )
        value
      elsif exact_hash_keys?(value, %i[
        kind string_index_type item_parents item_totals tax_detail_parents tax_descriptions
        tax_amounts summary_total
      ])
        value
      end
      return if evidence.nil?
      return unless evidence_value(evidence, :kind) == EVIDENCE_KIND
      return unless supported_index_type?(evidence_value(evidence, :string_index_type))

      item_parents = evidence_value(evidence, :item_parents)
      item_totals = evidence_value(evidence, :item_totals)
      tax_parents = evidence_value(evidence, :tax_detail_parents)
      tax_descriptions = evidence_value(evidence, :tax_descriptions)
      tax_amounts = evidence_value(evidence, :tax_amounts)
      summary_total = evidence_value(evidence, :summary_total)
      return unless item_parents.is_a?(Array) && item_parents.size == item_count
      return unless item_totals.is_a?(Array) && item_totals.size == item_count
      return unless tax_parents.is_a?(Array) && tax_parents.size.between?(1, MAX_ITEMS)
      return unless tax_descriptions.is_a?(Array) && tax_descriptions.size == tax_parents.size
      return unless tax_amounts.is_a?(Array) && tax_amounts.size <= tax_parents.size

      return unless item_parents.each_with_index.all? do |parent, item_index|
        valid_parent?(
          parent,
          expected_path: "documents[0].fields.Items[#{item_index}]",
          index_key: :item_index,
          index: item_index
        )
      end
      return unless parent_groups_disjoint?(item_parents)
      return unless item_totals.each_with_index.all? do |total, item_index|
        valid_line_evidence?(
          total,
          expected_path: "documents[0].fields.Items[#{item_index}].TotalPrice",
          index_type: evidence_value(evidence, :string_index_type),
          index_key: :item_index,
          index: item_index,
          maximum:
        ) && evidence_within_parent?(total, item_parents.fetch(item_index))
      end

      return unless tax_parents.each_with_index.all? do |parent, tax_detail_index|
        valid_parent?(
          parent,
          expected_path: "documents[0].fields.TaxDetails[#{tax_detail_index}]",
          index_key: :tax_detail_index,
          index: tax_detail_index
        )
      end
      return unless parent_groups_disjoint?(tax_parents)
      return unless tax_descriptions.each_with_index.all? do |description, tax_detail_index|
        valid_line_evidence?(
          description,
          expected_path: "documents[0].fields.TaxDetails[#{tax_detail_index}].Description",
          index_type: evidence_value(evidence, :string_index_type),
          index_key: :tax_detail_index,
          index: tax_detail_index,
          maximum: nil
        ) && evidence_within_parent?(description, tax_parents.fetch(tax_detail_index))
      end
      amount_indexes = tax_amounts.filter_map { |amount| parent_index(amount, :tax_detail_index) }
      return unless amount_indexes.uniq == amount_indexes && amount_indexes == amount_indexes.sort
      return unless tax_amounts.all? do |amount|
        tax_detail_index = parent_index(amount, :tax_detail_index)
        tax_detail_index.is_a?(Integer) && tax_detail_index.between?(0, tax_parents.size - 1) &&
          valid_line_evidence?(
            amount,
            expected_path: "documents[0].fields.TaxDetails[#{tax_detail_index}].Amount",
            index_type: evidence_value(evidence, :string_index_type),
            index_key: :tax_detail_index,
            index: tax_detail_index,
            maximum:
          ) && evidence_within_parent?(amount, tax_parents.fetch(tax_detail_index))
      end
      return unless valid_line_evidence?(
        summary_total,
        expected_path: nil,
        expected_provider: "azure_document_total",
        index_type: evidence_value(evidence, :string_index_type),
        maximum:
      )
      return if item_parents.any? { |parent| evidence_overlaps_parent?(summary_total, parent) }
      return if tax_parents.any? { |parent| evidence_overlaps_parent?(summary_total, parent) }
      return if item_parents.any? do |item_parent|
        tax_parents.any? { |tax_parent| parent_groups_overlap?(item_parent, tax_parent) }
      end

      total_sum = item_totals.sum { |total| exact_integer(evidence_value(total, :amount), maximum:, positive: false) }
      return unless total_sum == exact_integer(evidence_value(summary_total, :amount), maximum:, positive: false)

      evidence
    end

    def valid_parent?(value, expected_path:, index_key:, index:)
      return false unless exact_hash_keys?(
        value,
        %i[source_provider source_field_path provider_spans] + [ index_key ]
      )
      return false unless evidence_value(value, :source_provider) == SOURCE_PROVIDER
      return false unless evidence_value(value, :source_field_path) == expected_path
      return false unless parent_index(value, index_key) == index

      spans = evidence_value(value, :provider_spans)
      spans.is_a?(Array) && spans.size.between?(1, 16) &&
        spans.all? { |span| valid_span?(span) } &&
        spans.each_cons(2).all? do |left, right|
          evidence_value(left, :provider_span_end) <= evidence_value(right, :provider_span_start)
        end
    end

    def valid_line_evidence?(
      value,
      expected_path:,
      index_type:,
      maximum:,
      expected_provider: SOURCE_PROVIDER,
      index_key: nil,
      index: nil
    )
      required = %i[
        source_provider source_field_path page_index line_index string_index_type
        provider_span_start provider_span_end
      ]
      required << index_key if index_key
      allowed = required + %i[amount]
      return false unless optional_hash_keys?(value, required:, allowed:)
      return false unless evidence_value(value, :source_provider) == expected_provider
      return false unless evidence_value(value, :page_index) == 0
      return false unless evidence_value(value, :line_index).is_a?(Integer)
      return false unless evidence_value(value, :line_index).between?(0, MAX_LINES - 1)
      return false unless evidence_value(value, :string_index_type) == index_type
      return false if index_key && parent_index(value, index_key) != index

      actual_path = expected_path || "pages[0].lines[#{evidence_value(value, :line_index)}]"
      return false unless evidence_value(value, :source_field_path) == actual_path
      return false unless valid_span?(value)

      maximum.nil? || !exact_integer(evidence_value(value, :amount), maximum:, positive: false).nil?
    end

    def reference_projection(candidate, maximum:)
      result = ReceiptAmountService.reference_item_extension_projection(
        reference_price_amount: candidate.dig(:reference_price, :amount),
        reference_quantity: candidate.dig(:reference_quantity, :amount),
        reference_unit_code: candidate.dig(:reference_quantity, :unit_code),
        purchased_quantity: candidate.dig(:purchased_quantity, :amount),
        purchased_unit_code: candidate.dig(:purchased_quantity, :unit_code)
      )
      amount = result.fetch(:projected_amount)
      result if exact_integer(amount, maximum:, positive: false)
    rescue ReceiptAmountService::InvalidItemSourceError
      nil
    end

    def candidate_amounts_match?(entry, evidence:, maximum:)
      candidate = entry.fetch(:candidate)
      projection = entry.fetch(:projection)
      item_index = candidate.fetch(:item_index)
      projected = projection.fetch(:projected_amount)
      printed = exact_integer(candidate.dig(:printed_line_total, :amount), maximum:, positive: false)
      evidence_total = exact_integer(
        evidence_value(evidence_value(evidence, :item_totals).fetch(item_index), :amount),
        maximum:,
        positive: false
      )
      corroboration = candidate[:corroboration]
      return false unless corroboration.is_a?(Hash)
      return false unless exact_integer(corroboration[:projected_amount], maximum:, positive: false) == projected
      return false unless exact_integer(corroboration[:printed_line_total], maximum:, positive: false) == printed
      return false unless corroboration_exact_amount_valid?(
        corroboration[:exact_amount],
        projection.fetch(:exact_amount)
      )

      projected == printed && printed == evidence_total
    end

    def corroboration_exact_amount_valid?(value, exact_amount)
      exact_hash_keys?(value, %i[denominator numerator]) &&
        value[:numerator] == exact_amount.numerator.to_s &&
        value[:denominator] == exact_amount.denominator.to_s
    end

    def parent_groups_disjoint?(parents)
      parents.combination(2).none? { |left, right| parent_groups_overlap?(left, right) }
    end

    def parent_groups_overlap?(left, right)
      evidence_value(left, :provider_spans).any? do |left_span|
        evidence_value(right, :provider_spans).any? do |right_span|
          evidence_ranges_overlap?(left_span, right_span)
        end
      end
    end

    def evidence_within_parent?(value, parent)
      evidence_value(parent, :provider_spans).one? do |span|
        evidence_value(value, :provider_span_start) >= evidence_value(span, :provider_span_start) &&
          evidence_value(value, :provider_span_end) <= evidence_value(span, :provider_span_end)
      end
    end

    def evidence_overlaps_parent?(value, parent)
      evidence_value(parent, :provider_spans).any? { |span| evidence_ranges_overlap?(value, span) }
    end

    def evidence_ranges_overlap?(left, right)
      evidence_value(left, :provider_span_start) < evidence_value(right, :provider_span_end) &&
        evidence_value(right, :provider_span_start) < evidence_value(left, :provider_span_end)
    end

    def valid_span?(value)
      start_value = evidence_value(value, :provider_span_start)
      end_value = evidence_value(value, :provider_span_end)
      start_value.is_a?(Integer) && end_value.is_a?(Integer) &&
        start_value.between?(0, MAX_PROVIDER_SPAN) && end_value > start_value &&
        end_value <= MAX_PROVIDER_SPAN
    end

    def supported_index_type?(value)
      Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: value).present?
    end

    def exact_decimal(value, maximum:)
      return unless value.is_a?(String) && value.bytesize <= MAX_NUMBER_BYTES
      return unless value.match?(EXACT_DECIMAL_PATTERN)

      decimal = BigDecimal(value)
      decimal if decimal >= 0 && decimal <= maximum
    rescue ArgumentError
      nil
    end

    def exact_integer(value, maximum:, positive:)
      return unless value.is_a?(Integer) || value.is_a?(String)

      integer = Integer(value, exception: false)
      return if integer.nil? || integer.to_s != value.to_s
      return unless integer.between?(positive ? 1 : 0, maximum)

      integer
    end

    def valid_amount_limit?(value)
      value.is_a?(Integer) && value.between?(1, MAX_AMOUNT)
    end

    def exact_hash_keys?(value, keys)
      value.is_a?(Hash) && value.keys.map(&:to_sym).sort == keys.sort
    end

    def optional_hash_keys?(value, required:, allowed:)
      return false unless value.is_a?(Hash)

      keys = value.keys.map(&:to_sym)
      (required - keys).empty? && (keys - allowed).empty?
    end

    def parent_index(value, key)
      evidence_value(value, key)
    end

    def evidence_value(value, key)
      return value.public_send(key) if value.respond_to?(key)
      return value[key] if value.is_a?(Hash) && value.key?(key)

      value[key.to_s] if value.is_a?(Hash)
    end

    def result(reason, eligible: false, **attributes)
      bounded_reason = REASONS.include?(reason) ? reason : "candidate_invalid"
      Result.new(eligible:, reason: bounded_reason, **attributes)
    end
  end
end
