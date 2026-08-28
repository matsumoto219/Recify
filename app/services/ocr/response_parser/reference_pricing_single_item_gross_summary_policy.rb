class Ocr::ResponseParser::ReferencePricingSingleItemGrossSummaryPolicy
  CONTRACT_VERSION = "reference_pricing_single_item_gross_summary_policy_v1"
  EVIDENCE_KIND = "single_item_receipt_gross_summary"
  SOURCE_KIND = "azure_item_layout"
  VALIDATION_CONTRACT_VERSION = "azure_item_layout_v1"
  SUPPORTED_MODEL_ID = "prebuilt-receipt"
  SUPPORTED_API_VERSION = "2024-11-30"
  ELIGIBLE_REASON = "eligible"
  REASONS = %w[
    eligible
    amount_limit_invalid
    candidate_invalid
    receipt_scope_invalid
    conflict_present
    evidence_invalid
    summary_total_invalid
    tax_group_invalid
    projection_invalid
    amount_mismatch
  ].freeze
  REFERENCE_PRICE_KEYS = %i[amount evidence].freeze
  REFERENCE_QUANTITY_KEYS = %i[amount unit_code unit_status origin evidence].freeze
  PURCHASED_QUANTITY_KEYS = %i[amount unit_code unit_status evidence].freeze
  PRINTED_LINE_TOTAL_KEYS = %i[amount evidence].freeze
  EVIDENCE_KEYS = %i[
    source_provider
    source_field_path
    page_index
    line_index
    string_index_type
    provider_span_start
    provider_span_end
  ].freeze
  SUMMARY_TOTAL_KEYS = (EVIDENCE_KEYS + %i[amount]).freeze
  GROSS_TAX_TARGET_KEYS = (EVIDENCE_KEYS + %i[rate net_amount tax_amount gross_amount]).freeze
  CANDIDATE_ID_PATTERN = /
    \Aazure_item_layout_p0_name_l(?<name_line_index>0|[1-9]\d*)
    _ref_l(?<reference_line_index>0|[1-9]\d*)
    _qty_l(?<quantity_line_index>0|[1-9]\d*)
    _total_l(?<total_line_index>0|[1-9]\d*)_reference_pricing\z
  /x.freeze
  STRUCTURED_ITEM_IDENTITY_PATTERN = /
    \Aazure_structured_item_i(?<item_index>0|[1-9]\d*)
    _s(?<provider_span_start>0|[1-9]\d*)_e(?<provider_span_end>0|[1-9]\d*)\z
  /x.freeze
  EXACT_DECIMAL_PATTERN = /\A(?:0|[1-9]\d*)(?:\.\d+)?\z/.freeze
  MAX_ID_BYTES = 160
  MAX_NUMBER_BYTES = 64
  MAX_LINE_INDEX = Ocr::ResponseParser::ReferencePricingItemLayoutExtractor::MAX_LINES - 1
  MAX_ITEM_INDEX = Ocr::ResponseParser::ReferencePricingItemLayoutExtractor::MAX_ITEMS - 1
  MAX_PROVIDER_SPAN = Ocr::ResponseParser::AzureStringIndexMapper::MAX_PROVIDER_INDEX
  MAX_PRICE_AMOUNT = Ocr::ResponseParser::ReferencePricingCandidateExtractor::MAX_PRICE_AMOUNT
  MAX_QUANTITY = Ocr::ResponseParser::ReferencePricingCandidateExtractor::MAX_QUANTITY
  MAX_PRICE_SCALE = Ocr::ResponseParser::ReferencePricingCandidateExtractor::MAX_PRICE_SCALE
  MAX_QUANTITY_SCALE = Ocr::ResponseParser::ReferencePricingCandidateExtractor::MAX_QUANTITY_SCALE
  PRODUCER_METADATA_OFFSETS = [
    { reference: 1, reference_quantity: 1, purchased: [ 2 ], total: 3, owned: [ 0, 1, 2, 3 ] },
    { reference: 1, reference_quantity: 1, purchased: [ 3 ], total: 4, owned: [ 0, 1, 2, 3, 4 ] },
    { reference: 1, reference_quantity: 1, purchased: [ 2, 3 ], total: 4, owned: [ 0, 1, 2, 3, 4 ] },
    { reference: 2, reference_quantity: 2, purchased: [ 1 ], total: 3, owned: [ 0, 1, 2, 3 ] },
    { reference: 2, reference_quantity: 1, purchased: [ 3 ], total: 4, owned: [ 0, 1, 2, 3, 4 ] }
  ].freeze

  Result = Data.define(
    :eligible,
    :reason,
    :reference_price_tax_inclusion,
    :evidence_kind,
    :candidate_id,
    :item_identity,
    :contract_version
  ) do
    def initialize(
      eligible:,
      reason:,
      reference_price_tax_inclusion: nil,
      evidence_kind: nil,
      candidate_id: nil,
      item_identity: nil
    )
      super(
        eligible: eligible == true,
        reason: reason.to_s.dup.freeze,
        reference_price_tax_inclusion: reference_price_tax_inclusion&.dup&.freeze,
        evidence_kind: evidence_kind&.dup&.freeze,
        candidate_id: candidate_id&.dup&.freeze,
        item_identity: item_identity&.dup&.freeze,
        contract_version: CONTRACT_VERSION.dup.freeze
      )
    end

    def eligible?
      eligible == true
    end
  end

  class << self
    def call(
      candidate:,
      item_identities:,
      block_candidate_ids:,
      destination_identities:,
      summary_gross_evidence:,
      adjustment_count:,
      discount_count:,
      competing_tax_basis_count:,
      item_line_total_limit:
    )
      return result("amount_limit_invalid") unless valid_amount_limit?(item_line_total_limit)

      candidate_metadata = exact_candidate_metadata(candidate, item_line_total_limit:)
      return result("candidate_invalid") if candidate_metadata.nil?
      return result("receipt_scope_invalid") unless exact_single_scope?(
        candidate:,
        item_identities:,
        block_candidate_ids:,
        destination_identities:
      )
      return result("conflict_present") unless no_conflicts?(
        adjustment_count:,
        discount_count:,
        competing_tax_basis_count:
      )

      return result("evidence_invalid") unless valid_evidence_envelope?(summary_gross_evidence, candidate)

      summary_total = exact_summary_total(
        summary_gross_evidence.summary_total,
        maximum: item_line_total_limit,
        string_index_type: candidate[:string_index_type]
      )
      return result("summary_total_invalid") if summary_total.nil?

      tax_group = exact_tax_group(
        summary_gross_evidence.gross_tax_target,
        maximum: item_line_total_limit,
        string_index_type: candidate[:string_index_type]
      )
      return result("tax_group_invalid") if tax_group.nil?
      return result("evidence_invalid") unless evidence_ranges_disjoint?(candidate_metadata, summary_total, tax_group)

      projected_amount = projected_amount(candidate, maximum: item_line_total_limit)
      return result("projection_invalid") if projected_amount.nil?

      printed_line_total = exact_integer(
        candidate.dig(:printed_line_total, :amount),
        maximum: item_line_total_limit,
        positive: true
      )
      amounts = [
        projected_amount,
        printed_line_total,
        tax_group.fetch(:gross_amount),
        summary_total.fetch(:amount)
      ]
      return result("amount_mismatch") unless amounts.uniq.one?

      result(
        ELIGIBLE_REASON,
        eligible: true,
        reference_price_tax_inclusion: "gross",
        evidence_kind: EVIDENCE_KIND,
        candidate_id: candidate.fetch(:candidate_id),
        item_identity: candidate.fetch(:item_identity)
      )
    rescue EncodingError, ArgumentError, KeyError, TypeError
      result("candidate_invalid")
    end

    private

    def exact_candidate_metadata(candidate, item_line_total_limit:)
      return unless candidate.is_a?(Hash)
      return unless candidate[:source_kind] == SOURCE_KIND
      return unless candidate[:provider_model_id] == SUPPORTED_MODEL_ID
      return unless candidate[:provider_api_version] == SUPPORTED_API_VERSION
      return unless supported_index_type?(candidate[:string_index_type])
      return unless candidate[:validation_contract_version] == VALIDATION_CONTRACT_VERSION
      return unless candidate[:validation_state] == "ambiguous"
      return unless candidate[:rejection_reasons] == [ "ambiguous_tax_inclusion" ]
      return unless candidate[:reference_price_tax_inclusion] == "unknown"

      metadata = candidate_id_metadata(candidate[:candidate_id])
      return if metadata.nil?
      identity_metadata = item_identity_metadata(candidate[:item_identity])
      return if identity_metadata.nil?
      descriptor_metadata = exact_descriptor_metadata(candidate, metadata, identity_metadata)
      return if descriptor_metadata.nil?
      return unless valid_reference_price?(
        candidate[:reference_price],
        candidate[:string_index_type],
        expected_line_index: metadata.fetch(:reference_line_index)
      )
      return unless valid_quantity?(
        candidate[:reference_quantity],
        string_index_type: candidate[:string_index_type],
        origin_required: true,
        expected_line_index: descriptor_metadata.fetch(:reference_quantity_line_index)
      )
      return unless valid_quantity?(
        candidate[:purchased_quantity],
        string_index_type: candidate[:string_index_type],
        origin_required: false,
        expected_line_index: metadata.fetch(:quantity_line_index)
      )
      return unless valid_printed_line_total?(
        candidate[:printed_line_total],
        candidate[:string_index_type],
        expected_line_index: metadata.fetch(:total_line_index),
        maximum: item_line_total_limit
      )

      return unless ReceiptQuantityUnit.convertible?(
        from: candidate.dig(:purchased_quantity, :unit_code),
        to: candidate.dig(:reference_quantity, :unit_code)
      )
      return unless component_evidence_order_valid?(candidate)

      metadata.merge(descriptor_metadata)
    end

    def valid_reference_price?(component, string_index_type, expected_line_index:)
      return false unless exact_keys?(component, REFERENCE_PRICE_KEYS)
      return false unless exact_decimal(
        component[:amount],
        maximum: MAX_PRICE_AMOUNT,
        maximum_scale: MAX_PRICE_SCALE,
        positive: false
      )

      valid_evidence?(component[:evidence], string_index_type, expected_line_index:)
    end

    def valid_quantity?(component, string_index_type:, origin_required:, expected_line_index:)
      required_keys = origin_required ? REFERENCE_QUANTITY_KEYS : PURCHASED_QUANTITY_KEYS
      return false unless exact_keys?(component, required_keys)
      return false unless exact_decimal(
        component[:amount],
        maximum: MAX_QUANTITY,
        maximum_scale: MAX_QUANTITY_SCALE,
        positive: true
      )
      return false unless component[:unit_status] == "known"

      unit = ReceiptQuantityUnit.unit_for(component[:unit_code])
      return false unless unit&.allows_pricing_role?(origin_required ? :reference : :purchased)
      return false if origin_required && !%w[explicit implicit_per_unit].include?(component[:origin])

      valid_evidence?(component[:evidence], string_index_type, expected_line_index:)
    end

    def valid_printed_line_total?(component, string_index_type, expected_line_index:, maximum:)
      return false unless exact_keys?(component, PRINTED_LINE_TOTAL_KEYS)
      return false if exact_integer(component[:amount], maximum:, positive: true).nil?

      valid_evidence?(component[:evidence], string_index_type, expected_line_index:)
    end

    def valid_evidence?(evidence, string_index_type, expected_line_index:)
      return false unless exact_keys?(evidence, EVIDENCE_KEYS)
      return false unless evidence[:source_provider] == SOURCE_KIND
      return false unless evidence[:page_index] == 0
      return false unless evidence[:line_index] == expected_line_index
      return false unless evidence[:source_field_path] == "pages[0].lines[#{evidence[:line_index]}]"
      return false unless evidence[:string_index_type] == string_index_type

      valid_span?(evidence[:provider_span_start], evidence[:provider_span_end])
    end

    def supported_index_type?(value)
      value.is_a?(String) && Ocr::ResponseParser::AzureStringIndexMapper::SUPPORTED_INDEX_TYPES.include?(value)
    end

    def candidate_id_metadata(value)
      match = bounded_match(value, CANDIDATE_ID_PATTERN)
      return if match.nil?

      line_index_metadata(match)
    end

    def item_identity_metadata(value)
      structured_match = bounded_match(value, STRUCTURED_ITEM_IDENTITY_PATTERN)
      return if structured_match.nil?

      item_index = Integer(structured_match[:item_index], 10)
      span_start = Integer(structured_match[:provider_span_start], 10)
      span_end = Integer(structured_match[:provider_span_end], 10)
      return unless item_index.between?(0, MAX_ITEM_INDEX) && valid_span?(span_start, span_end)

      {
        destination_kind: "azure_structured_item",
        structured_item_index: item_index,
        provider_span_start: span_start,
        provider_span_end: span_end
      }
    rescue EncodingError, ArgumentError, TypeError
      nil
    end

    def line_index_metadata(match)
      metadata = {
        name_line_index: Integer(match[:name_line_index], 10),
        reference_line_index: Integer(match[:reference_line_index], 10),
        quantity_line_index: Integer(match[:quantity_line_index], 10),
        total_line_index: Integer(match[:total_line_index], 10)
      }
      return unless metadata.values.all? { |line_index| line_index.between?(0, MAX_LINE_INDEX) }

      offsets = [
        metadata.fetch(:reference_line_index) - metadata.fetch(:name_line_index),
        metadata.fetch(:quantity_line_index) - metadata.fetch(:name_line_index),
        metadata.fetch(:total_line_index) - metadata.fetch(:name_line_index)
      ]
      metadata if PRODUCER_METADATA_OFFSETS.any? do |producer|
        [ producer.fetch(:reference), producer.fetch(:purchased).last, producer.fetch(:total) ] == offsets
      end
    rescue ArgumentError, TypeError
      nil
    end

    def exact_descriptor_metadata(candidate, identity_metadata, item_identity_metadata)
      return unless candidate[:page_index] == 0

      item_index = candidate[:item_index]
      return unless item_index.is_a?(Integer) && item_index.between?(0, MAX_ITEM_INDEX)
      return unless destination_metadata_valid?(candidate, item_index, item_identity_metadata)
      return unless candidate[:name_line_index] == identity_metadata.fetch(:name_line_index)
      return unless candidate[:reference_line_index] == identity_metadata.fetch(:reference_line_index)
      return unless candidate[:printed_total_line_index] == identity_metadata.fetch(:total_line_index)

      purchased_line_indexes = candidate[:purchased_quantity_line_indexes]
      owned_line_indexes = candidate[:owned_line_indexes]
      return unless purchased_line_indexes.is_a?(Array) && purchased_line_indexes.present?
      return unless purchased_line_indexes.last == identity_metadata.fetch(:quantity_line_index)
      return unless owned_line_indexes.is_a?(Array)

      name_line_index = identity_metadata.fetch(:name_line_index)
      actual_offsets = {
        reference: identity_metadata.fetch(:reference_line_index) - name_line_index,
        purchased: purchased_line_indexes.map { |line_index| line_index - name_line_index },
        total: identity_metadata.fetch(:total_line_index) - name_line_index,
        owned: owned_line_indexes.map { |line_index| line_index - name_line_index }
      }
      producer_metadata = PRODUCER_METADATA_OFFSETS.find do |producer|
        producer.except(:reference_quantity) == actual_offsets
      end
      return if producer_metadata.nil?

      block_start = candidate[:block_provider_span_start]
      block_end = candidate[:block_provider_span_end]
      return unless valid_span?(block_start, block_end)
      reference_line_start = candidate[:reference_line_provider_span_start]
      reference_line_end = candidate[:reference_line_provider_span_end]
      return unless valid_span?(reference_line_start, reference_line_end)
      return unless reference_line_start >= block_start && reference_line_end <= block_end
      return unless reference_line_evidence_valid?(
        candidate,
        reference_line_start:,
        reference_line_end:,
        reference_line_index: identity_metadata.fetch(:reference_line_index)
      )
      return unless candidate_component_evidence(candidate).all? do |evidence|
        span_within?(evidence, block_start, block_end)
      end
      return unless structured_parent_valid?(
        candidate,
        item_identity_metadata,
        block_start:,
        block_end:,
        reference_line_end:
      )

      {
        block_provider_span_start: block_start,
        block_provider_span_end: block_end,
        structured_parent_span_start: item_identity_metadata.fetch(:provider_span_start),
        structured_parent_span_end: item_identity_metadata.fetch(:provider_span_end),
        owned_line_indexes: owned_line_indexes,
        reference_quantity_line_index: name_line_index + producer_metadata.fetch(:reference_quantity)
      }
    rescue ArgumentError, KeyError, NoMethodError, TypeError
      nil
    end

    def destination_metadata_valid?(candidate, item_index, identity_metadata)
      return false unless candidate[:destination_kind] == "azure_structured_item"

      structured_item_index = candidate[:structured_item_index]
      structured_item_index.is_a?(Integer) &&
        structured_item_index == identity_metadata.fetch(:structured_item_index) &&
        item_index == structured_item_index && structured_item_index.between?(0, MAX_ITEM_INDEX)
    end

    def reference_line_evidence_valid?(candidate, reference_line_start:, reference_line_end:, reference_line_index:)
      reference_evidence = [
        candidate.dig(:reference_price, :evidence),
        candidate.dig(:reference_quantity, :evidence)
      ]
      same_line_evidence = reference_evidence.select { |evidence| evidence[:line_index] == reference_line_index }
      same_line_evidence.present? && same_line_evidence.all? do |evidence|
        span_within?(evidence, reference_line_start, reference_line_end)
      end
    rescue KeyError, NoMethodError, TypeError
      false
    end

    def structured_parent_valid?(candidate, identity_metadata, block_start:, block_end:, reference_line_end:)
      parent_start = identity_metadata.fetch(:provider_span_start)
      parent_end = identity_metadata.fetch(:provider_span_end)
      full_block_parent = block_start >= parent_start && block_end <= parent_end
      return true if full_block_parent

      reference_evidence = [ candidate.dig(:reference_price, :evidence), candidate.dig(:reference_quantity, :evidence) ]
      purchased_start = candidate.dig(:purchased_quantity, :evidence, :provider_span_start)
      parent_start == block_start && parent_end == reference_line_end &&
        reference_evidence.all? { |evidence| span_within?(evidence, parent_start, parent_end) } &&
        parent_end < purchased_start
    rescue ArgumentError, KeyError, NoMethodError, TypeError
      false
    end

    def candidate_component_evidence(candidate)
      %i[
        reference_price
        reference_quantity
        purchased_quantity
        printed_line_total
      ].map { |component| candidate.dig(component, :evidence) }
    end

    def component_evidence_order_valid?(candidate)
      evidence = candidate_component_evidence(candidate)
      reference_price = evidence.fetch(0)
      reference_quantity = evidence.fetch(1)
      return false if reference_price.fetch(:line_index) == reference_quantity.fetch(:line_index) &&
        reference_price.fetch(:provider_span_end) > reference_quantity.fetch(:provider_span_start)

      evidence.combination(2).all? do |left, right|
        if left.fetch(:line_index) == right.fetch(:line_index)
          !ranges_overlap?(left, right)
        elsif left.fetch(:line_index) < right.fetch(:line_index)
          left.fetch(:provider_span_end) <= right.fetch(:provider_span_start)
        else
          right.fetch(:provider_span_end) <= left.fetch(:provider_span_start)
        end
      end
    rescue KeyError, NoMethodError, TypeError
      false
    end

    def span_within?(value, span_start, span_end)
      value.fetch(:provider_span_start) >= span_start && value.fetch(:provider_span_end) <= span_end
    end

    def bounded_match(value, pattern)
      return unless value.is_a?(String) && value.valid_encoding?
      return unless value.bytesize.between?(1, MAX_ID_BYTES)

      pattern.match(value)
    rescue EncodingError, ArgumentError, TypeError
      nil
    end

    def exact_single_scope?(candidate:, item_identities:, block_candidate_ids:, destination_identities:)
      return false unless [ item_identities, block_candidate_ids, destination_identities ].all? do |values|
        values.is_a?(Array) && values.one?
      end

      item_identity = candidate[:item_identity]
      candidate_id = candidate[:candidate_id]
      item_identities.sole == item_identity &&
        block_candidate_ids.sole == candidate_id &&
        destination_identities.sole == item_identity
    end

    def no_conflicts?(adjustment_count:, discount_count:, competing_tax_basis_count:)
      [ adjustment_count, discount_count, competing_tax_basis_count ].all? do |count|
        count.is_a?(Integer) && count.zero?
      end
    end

    def valid_evidence_envelope?(value, candidate)
      value.instance_of?(
        Ocr::ResponseParser::ReferencePricingSingleItemGrossSummaryEvidenceExtractor::Result
      ) &&
        value.kind == EVIDENCE_KIND &&
        supported_index_type?(value.string_index_type) &&
        value.string_index_type == candidate[:string_index_type]
    end

    def exact_summary_total(summary, maximum:, string_index_type:)
      return unless exact_keys?(summary, SUMMARY_TOTAL_KEYS)
      return unless valid_structural_evidence?(summary, string_index_type:)

      amount = exact_integer(summary[:amount], maximum:, positive: true)
      return if amount.nil?

      structural_result(summary).merge(amount: amount)
    end

    def exact_tax_group(group, maximum:, string_index_type:)
      return unless exact_keys?(group, GROSS_TAX_TARGET_KEYS)
      return unless valid_structural_evidence?(group, string_index_type:)

      rate = exact_rate(group[:rate])
      net_amount = exact_integer(group[:net_amount], maximum:, positive: false)
      tax_amount = exact_integer(group[:tax_amount], maximum:, positive: true)
      gross_amount = exact_integer(group[:gross_amount], maximum:, positive: true)
      return if [ rate, net_amount, tax_amount, gross_amount ].any?(&:nil?)

      expected_tax_amount = ReceiptAmountService.apply_rounding(
        BigDecimal(gross_amount.to_s) * rate / (BigDecimal("1") + rate),
        :floor
      )
      return unless tax_amount == expected_tax_amount
      return unless net_amount == gross_amount - expected_tax_amount

      structural_result(group).merge(
        rate: rate,
        net_amount: net_amount,
        tax_amount: tax_amount,
        gross_amount: gross_amount
      )
    end

    def valid_structural_evidence?(value, string_index_type:)
      return false unless value[:source_provider] == SOURCE_KIND
      return false unless value[:page_index] == 0
      return false unless value[:line_index].is_a?(Integer) && value[:line_index].between?(0, MAX_LINE_INDEX)
      return false unless value[:source_field_path] == "pages[0].lines[#{value[:line_index]}]"
      return false unless value[:string_index_type] == string_index_type

      valid_span?(value[:provider_span_start], value[:provider_span_end])
    end

    def structural_result(value)
      {
        line_index: value.fetch(:line_index),
        provider_span_start: value.fetch(:provider_span_start),
        provider_span_end: value.fetch(:provider_span_end)
      }
    end

    def evidence_ranges_disjoint?(candidate_metadata, summary_total, tax_group)
      external_evidence = [ summary_total, tax_group ]
      return false unless external_evidence.map { |evidence| evidence.fetch(:line_index) }.uniq.size == 2
      return false if ranges_overlap?(*external_evidence)

      external_evidence.all? do |external|
        evidence_outside_block?(external, candidate_metadata)
      end
    end

    def evidence_outside_block?(evidence, candidate_metadata)
      owned_line_indexes = candidate_metadata.fetch(:owned_line_indexes)
      scope_start = [
        candidate_metadata.fetch(:block_provider_span_start),
        candidate_metadata.fetch(:structured_parent_span_start)
      ].min
      scope_end = [
        candidate_metadata.fetch(:block_provider_span_end),
        candidate_metadata.fetch(:structured_parent_span_end)
      ].max
      before_block = evidence.fetch(:line_index) < owned_line_indexes.first &&
        evidence.fetch(:provider_span_end) <= scope_start
      after_block = evidence.fetch(:line_index) > owned_line_indexes.last &&
        evidence.fetch(:provider_span_start) >= scope_end
      before_block || after_block
    end

    def ranges_overlap?(left, right)
      left.fetch(:provider_span_start) < right.fetch(:provider_span_end) &&
        right.fetch(:provider_span_start) < left.fetch(:provider_span_end)
    end

    def exact_rate(value)
      return unless value.is_a?(String) && canonical_decimal_string?(value)

      decimal = BigDecimal(value)
      return unless decimal.finite? && decimal.positive? && decimal <= 1
      return if value != canonical_decimal(decimal)

      decimal
    rescue ArgumentError, TypeError
      nil
    end

    def exact_decimal(value, maximum:, maximum_scale:, positive:)
      return unless value.is_a?(String) && value.bytesize.between?(1, MAX_NUMBER_BYTES)
      return unless canonical_decimal_string?(value)

      decimal = BigDecimal(value)
      return unless decimal.finite? && decimal <= maximum
      return if positive ? !decimal.positive? : decimal.negative?
      return if decimal_scale(value) > maximum_scale

      decimal
    rescue ArgumentError, TypeError
      nil
    end

    def exact_integer(value, maximum:, positive:)
      integer = if value.is_a?(Integer)
        value
      elsif value.is_a?(String) && value.match?(/\A(?:0|[1-9]\d*)\z/) && value.bytesize <= MAX_NUMBER_BYTES
        Integer(value, 10)
      end
      return if integer.nil? || integer > maximum
      return if positive ? !integer.positive? : integer.negative?

      integer
    rescue ArgumentError, TypeError
      nil
    end

    def canonical_decimal_string?(value)
      return false unless value.valid_encoding? && value.match?(EXACT_DECIMAL_PATTERN)

      value == canonical_decimal(BigDecimal(value))
    rescue EncodingError, ArgumentError, TypeError
      false
    end

    def canonical_decimal(decimal)
      normalized = decimal.to_s("F")
      integer, fraction = normalized.split(".", 2)
      fraction = fraction&.sub(/0+\z/, "")
      fraction.present? ? "#{integer}.#{fraction}" : integer
    end

    def decimal_scale(value)
      value.include?(".") ? value.split(".", 2).last.length : 0
    end

    def valid_span?(span_start, span_end)
      span_start.is_a?(Integer) && span_end.is_a?(Integer) &&
        span_start.between?(0, MAX_PROVIDER_SPAN) && span_end > span_start && span_end <= MAX_PROVIDER_SPAN
    end

    def exact_keys?(value, keys)
      value.is_a?(Hash) && value.keys.sort == keys.sort
    rescue ArgumentError, TypeError
      false
    end

    def valid_amount_limit?(value)
      value.is_a?(Integer) && value.between?(1, MAX_PRICE_AMOUNT.to_i)
    end

    def projected_amount(candidate, maximum:)
      result = ReceiptAmountService.reference_item_extension_projection(
        reference_price_amount: candidate.dig(:reference_price, :amount),
        reference_quantity: candidate.dig(:reference_quantity, :amount),
        reference_unit_code: candidate.dig(:reference_quantity, :unit_code),
        purchased_quantity: candidate.dig(:purchased_quantity, :amount),
        purchased_unit_code: candidate.dig(:purchased_quantity, :unit_code)
      )
      exact_integer(result.fetch(:projected_amount), maximum:, positive: true)
    rescue ReceiptAmountService::InvalidItemSourceError, ArgumentError, KeyError, TypeError
      nil
    end

    def result(
      reason,
      eligible: false,
      reference_price_tax_inclusion: nil,
      evidence_kind: nil,
      candidate_id: nil,
      item_identity: nil
    )
      bounded_reason = REASONS.include?(reason) ? reason : "candidate_invalid"
      Result.new(
        eligible:,
        reason: bounded_reason,
        reference_price_tax_inclusion:,
        evidence_kind:,
        candidate_id:,
        item_identity:
      )
    end
  end
end
