class Ocr::ResponseParser::ReferencePricingSharedBasisExternalTaxPolicy
  CONTRACT_VERSION = "reference_pricing_shared_basis_external_tax_policy_v1"
  EVIDENCE_KIND = "shared_basis_external_tax_summary"
  SOURCE_KIND = "azure_item_layout"
  VALIDATION_CONTRACT_VERSION = "azure_item_layout_shared_basis_v1"
  SUPPORTED_MODEL_ID = "prebuilt-receipt"
  SUPPORTED_API_VERSION = "2024-11-30"
  STRUCTURED_SOURCE_PROVIDER = "azure_structured"
  TAX_INCLUSION = "net"
  TAX_ROUNDING_MODES = %i[floor round ceil].freeze
  ELIGIBLE_REASON = "eligible"
  REASONS = %w[
    eligible
    amount_limit_invalid
    candidate_invalid
    receipt_scope_invalid
    conflict_present
    evidence_invalid
    tax_detail_invalid
    projection_invalid
    amount_mismatch
  ].freeze
  CANDIDATE_ID_PATTERN = /
    \Aazure_item_layout_p0_name_l(?<name>0|[1-9]\d*)_ref_l(?<reference>0|[1-9]\d*)
    _qty_l(?<quantity>0|[1-9]\d*)_total_l(?<total>0|[1-9]\d*)_reference_pricing\z
  /x.freeze
  STRUCTURED_ITEM_IDENTITY_PATTERN = /
    \Aazure_structured_item_i(?<item_index>0|[1-9]\d*)
    _s(?<provider_span_start>0|[1-9]\d*)_e(?<provider_span_end>0|[1-9]\d*)\z
  /x.freeze
  EXACT_DECIMAL_PATTERN = /\A(?:0|[1-9]\d*)(?:\.\d+)?\z/.freeze
  EVIDENCE_KEYS = %i[
    source_provider
    source_field_path
    page_index
    line_index
    string_index_type
    provider_span_start
    provider_span_end
  ].freeze
  AMOUNT_EVIDENCE_KEYS = (EVIDENCE_KEYS + %i[amount]).freeze
  MAX_LINE_INDEX = Ocr::ResponseParser::ReferencePricingItemLayoutExtractor::MAX_LINES - 1
  MAX_PROVIDER_SPAN = Ocr::ResponseParser::AzureStringIndexMapper::MAX_PROVIDER_INDEX
  MAX_NUMBER_BYTES = 64

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
      external_tax_evidence:,
      tax_detail_structural_metadata:,
      adjustment_count:,
      discount_count:,
      item_line_total_limit:
    )
      return result("amount_limit_invalid") unless valid_amount_limit?(item_line_total_limit)

      candidate_metadata = exact_candidate(candidate, maximum: item_line_total_limit)
      return result("candidate_invalid") if candidate_metadata.nil?
      return result("receipt_scope_invalid") unless exact_single_scope?(
        candidate:,
        item_identities:,
        block_candidate_ids:,
        destination_identities:
      )
      return result("conflict_present") unless adjustment_count == 0 && discount_count == 0

      evidence = exact_external_tax_evidence(
        external_tax_evidence,
        candidate:,
        maximum: item_line_total_limit
      )
      return result("evidence_invalid") if evidence.nil?

      tax_detail = exact_tax_detail(
        tax_detail_structural_metadata,
        string_index_type: candidate.fetch(:string_index_type),
        maximum: item_line_total_limit,
        candidate_block: {
          provider_span_start: candidate.fetch(:block_provider_span_start),
          provider_span_end: candidate.fetch(:block_provider_span_end)
        }
      )
      return result("tax_detail_invalid") if tax_detail.nil?

      projection = reference_projection(candidate, maximum: item_line_total_limit)
      return result("projection_invalid") if projection.nil?

      amounts = [
        projection,
        exact_integer(candidate.dig(:printed_line_total, :amount), maximum: item_line_total_limit),
        exact_integer(candidate.dig(:corroboration, :projected_amount), maximum: item_line_total_limit),
        evidence.dig(:subtotal, :amount),
        tax_detail.dig(:net_amount, :amount)
      ]
      return result("amount_mismatch") if amounts.any?(&:nil?) || !amounts.uniq.one?

      taxes = [ evidence.dig(:document_tax_total, :amount), tax_detail.dig(:tax_amount, :amount) ]
      return result("amount_mismatch") if taxes.any?(&:nil?) || !taxes.uniq.one?
      return result("amount_mismatch") unless tax_amount_matches_rate?(tax_detail)
      return result("amount_mismatch") unless amounts.first + taxes.first == evidence.dig(:summary_total, :amount)

      result(
        ELIGIBLE_REASON,
        eligible: true,
        reference_price_tax_inclusion: TAX_INCLUSION,
        evidence_kind: EVIDENCE_KIND,
        candidate_id: candidate.fetch(:candidate_id),
        item_identity: candidate.fetch(:item_identity)
      )
    rescue EncodingError, ArgumentError, KeyError, NoMethodError, TypeError
      result("candidate_invalid")
    end

    private

    def exact_single_scope?(candidate:, item_identities:, block_candidate_ids:, destination_identities:)
      item_identities == [ candidate[:item_identity] ] &&
        block_candidate_ids == [ candidate[:candidate_id] ] &&
        destination_identities == [ candidate[:item_identity] ]
    end

    def exact_candidate(candidate, maximum:)
      return unless candidate.is_a?(Hash)
      return unless candidate[:source_kind] == SOURCE_KIND
      return unless candidate[:provider_model_id] == SUPPORTED_MODEL_ID
      return unless candidate[:provider_api_version] == SUPPORTED_API_VERSION
      return unless supported_index_type?(candidate[:string_index_type])
      return unless candidate[:validation_contract_version] == VALIDATION_CONTRACT_VERSION
      return unless candidate[:validation_state] == "ambiguous"
      return unless candidate[:rejection_reasons] == [ "ambiguous_tax_inclusion" ]
      return unless candidate[:reference_price_tax_inclusion] == "unknown"
      return unless candidate[:tax_inclusion_evidence].nil?
      return unless candidate[:destination_kind] == "azure_structured_item"
      return unless candidate[:item_index] == 0 && candidate[:structured_item_index] == 0
      return unless candidate[:page_index] == 0

      metadata = candidate_metadata(candidate)
      return if metadata.nil?

      identity = STRUCTURED_ITEM_IDENTITY_PATTERN.match(candidate[:item_identity].to_s)
      return if identity.nil? || identity[:item_index] != "0"
      parent_start = Integer(identity[:provider_span_start], 10)
      parent_end = Integer(identity[:provider_span_end], 10)
      return unless parent_end > parent_start
      return unless candidate[:block_provider_span_start] == parent_start
      return unless candidate[:block_provider_span_end] == parent_end

      return unless exact_owned_lines?(candidate, metadata:)
      return unless component_valid?(
        candidate[:reference_price],
        line_index: metadata.fetch(:reference),
        string_index_type: candidate[:string_index_type],
        maximum:,
        parent_start:,
        parent_end:
      )
      return unless component_valid?(
        candidate[:reference_quantity],
        line_index: candidate.fetch(:owned_line_indexes).first,
        string_index_type: candidate[:string_index_type],
        maximum:,
        outside_parent: true,
        parent_start:,
        parent_end:
      )
      return unless component_valid?(
        candidate[:purchased_quantity],
        line_index: metadata.fetch(:quantity),
        string_index_type: candidate[:string_index_type],
        maximum:,
        parent_start:,
        parent_end:
      )
      return unless component_valid?(
        candidate[:printed_line_total],
        line_index: metadata.fetch(:total),
        string_index_type: candidate[:string_index_type],
        maximum:,
        parent_start:,
        parent_end:
      )
      return unless candidate.dig(:reference_quantity, :origin) == "explicit"
      return unless candidate.dig(:reference_quantity, :unit_status) == "known"
      return unless candidate.dig(:purchased_quantity, :unit_status) == "known"
      return unless ReceiptQuantityUnit.convertible?(
        from: candidate.dig(:purchased_quantity, :unit_code),
        to: candidate.dig(:reference_quantity, :unit_code)
      )

      metadata.merge(parent_start:, parent_end:)
    end

    def candidate_metadata(candidate)
      match = CANDIDATE_ID_PATTERN.match(candidate[:candidate_id].to_s)
      return if match.nil?

      metadata = %i[name reference quantity total].index_with do |key|
        Integer(match[key], 10)
      end
      return unless metadata.values.all? { |index| index.between?(0, MAX_LINE_INDEX) }
      return unless metadata.values.each_cons(2).all? { |left, right| left < right }
      return unless candidate[:name_line_index] == metadata.fetch(:name)
      return unless candidate[:reference_line_index] == metadata.fetch(:reference)
      return unless candidate[:purchased_quantity_line_indexes] == [ metadata.fetch(:quantity) ]
      return unless candidate[:printed_total_line_index] == metadata.fetch(:total)

      metadata
    end

    def exact_owned_lines?(candidate, metadata:)
      row_indexes = (metadata.fetch(:name)..metadata.fetch(:total)).to_a
      return false unless row_indexes.size.between?(4, 5)

      owned = candidate[:owned_line_indexes]
      return false unless owned.is_a?(Array) && owned.size <= 6

      header_index = owned.first
      header_index.is_a?(Integer) &&
        (metadata.fetch(:name) - header_index).between?(1, 4) &&
        owned == [ header_index, *row_indexes ]
    end

    def component_valid?(
      component,
      line_index:,
      string_index_type:,
      maximum:,
      parent_start:,
      parent_end:,
      outside_parent: false
    )
      return false unless component.is_a?(Hash)
      return false if exact_decimal(component[:amount], maximum:).nil?

      evidence = component[:evidence]
      return false unless evidence.is_a?(Hash)
      return false unless evidence[:source_provider] == SOURCE_KIND
      return false unless evidence[:source_field_path] == "pages[0].lines[#{line_index}]"
      return false unless evidence[:page_index] == 0 && evidence[:line_index] == line_index
      return false unless evidence[:string_index_type] == string_index_type

      span_start = bounded_index(evidence[:provider_span_start])
      span_end = bounded_index(evidence[:provider_span_end])
      return false if span_start.nil? || span_end.nil? || span_end <= span_start

      if outside_parent
        span_end <= parent_start
      else
        span_start >= parent_start && span_end <= parent_end
      end
    end

    def exact_external_tax_evidence(value, candidate:, maximum:)
      evidence = if value.is_a?(
        Ocr::ResponseParser::ReferencePricingSharedBasisExternalTaxEvidenceExtractor::Result
      )
        value.to_h
      else
        value
      end
      return unless evidence.is_a?(Hash)
      return unless evidence.keys.sort == %i[
        kind string_index_type tax_detail_index subtotal document_tax_total summary_total
      ].sort
      return unless evidence[:kind] == EVIDENCE_KIND
      return unless evidence[:string_index_type] == candidate[:string_index_type]
      return unless evidence[:tax_detail_index] == 0

      entries = {
        subtotal: "documents[0].fields.Subtotal",
        document_tax_total: "documents[0].fields.TotalTax",
        summary_total: "documents[0].fields.Total"
      }
      validated = entries.to_h do |key, expected_path|
        entry = exact_amount_evidence(
          evidence[key],
          expected_path:,
          string_index_type: candidate[:string_index_type],
          maximum:
        )
        return if entry.nil?

        [ key, entry ]
      end
      return unless validated.values.combination(2).none? { |left, right| ranges_overlap?(left, right) }
      return unless validated.values.all? do |entry|
        !ranges_overlap?(
          entry,
          {
            provider_span_start: candidate[:block_provider_span_start],
            provider_span_end: candidate[:block_provider_span_end]
          }
        )
      end

      validated
    end

    def exact_tax_detail(value, string_index_type:, maximum:, candidate_block:)
      return unless value.is_a?(Ocr::ResponseParser::StructuredTaxDetailMetadataExtractor::Result)
      return unless value.source_provider == STRUCTURED_SOURCE_PROVIDER
      return unless value.provider_model_id == SUPPORTED_MODEL_ID
      return unless value.provider_api_version == SUPPORTED_API_VERSION
      return unless value.string_index_type == string_index_type
      return unless value.tax_details.is_a?(Array) && value.tax_details.one?

      detail = value.tax_details.sole
      return unless detail.is_a?(Hash) && detail[:tax_detail_index] == 0

      parent = detail[:parent]
      tax_inclusion = detail[:tax_inclusion_evidence]
      return unless exact_tax_parent?(parent)
      return unless exact_tax_inclusion?(tax_inclusion, parent:, string_index_type:)

      rate = exact_tax_rate(
        detail[:rate],
        parent:,
        string_index_type:
      )
      net_amount = exact_tax_amount(
        detail[:net_amount],
        expected_path: "documents[0].fields.TaxDetails[0].NetAmount",
        parent:,
        string_index_type:,
        maximum:
      )
      tax_amount = exact_tax_amount(
        detail[:tax_amount],
        expected_path: "documents[0].fields.TaxDetails[0].Amount",
        parent:,
        string_index_type:,
        maximum:
      )
      return if rate.nil? || net_amount.nil? || tax_amount.nil?
      return unless [ tax_inclusion, rate, net_amount, tax_amount ].combination(2).none? do |left, right|
        ranges_overlap?(left, right)
      end
      return unless tax_detail_disjoint_from_candidate_block?(
        parent:,
        children: [ tax_inclusion, rate, net_amount, tax_amount ],
        candidate_block:
      )

      { parent:, rate:, net_amount:, tax_amount: }
    end

    def tax_amount_matches_rate?(tax_detail)
      rate = BigDecimal(tax_detail.dig(:rate, :rate))
      net_amount = tax_detail.dig(:net_amount, :amount)
      tax_amount = tax_detail.dig(:tax_amount, :amount)
      return false unless net_amount.is_a?(Integer) && tax_amount.is_a?(Integer)

      exact_tax = BigDecimal(net_amount.to_s) * rate
      TAX_ROUNDING_MODES.any? do |rounding_mode|
        ReceiptAmountService.apply_rounding(exact_tax, rounding_mode) == tax_amount
      end
    rescue ArgumentError, TypeError
      false
    end

    def tax_detail_disjoint_from_candidate_block?(parent:, children:, candidate_block:)
      return false unless bounded_span?(candidate_block)

      parent_spans = parent[:provider_spans]
      return false unless parent_spans.is_a?(Array) && parent_spans.all? do |span|
        !ranges_overlap?(span, candidate_block)
      end

      children.all? { |child| !ranges_overlap?(child, candidate_block) }
    end

    def exact_tax_parent?(value)
      return false unless value.is_a?(Hash)
      return false unless value[:source_provider] == STRUCTURED_SOURCE_PROVIDER
      return false unless value[:source_field_path] == "documents[0].fields.TaxDetails[0]"
      return false unless value[:tax_detail_index] == 0

      spans = value[:provider_spans]
      spans.is_a?(Array) && spans.size.between?(1, 16) && spans.all? do |span|
        bounded_span?(span)
      end && spans.each_cons(2).all? do |left, right|
        left[:provider_span_end] <= right[:provider_span_start]
      end
    end

    def exact_tax_inclusion?(value, parent:, string_index_type:)
      return false unless value.is_a?(Hash)
      return false unless value[:kind] == "external_tax" && value[:tax_inclusion] == TAX_INCLUSION
      return false unless value[:source_provider] == STRUCTURED_SOURCE_PROVIDER
      return false unless value[:source_field_path] == "documents[0].fields.TaxDetails[0].Description"
      return false unless value[:tax_detail_index] == 0
      return false unless value[:string_index_type] == string_index_type

      evidence_within_parent?(value, parent:)
    end

    def exact_tax_rate(value, parent:, string_index_type:)
      return unless value.is_a?(Hash)
      return unless value[:source_provider] == STRUCTURED_SOURCE_PROVIDER
      return unless value[:source_field_path] == "documents[0].fields.TaxDetails[0].Rate"
      return unless value[:tax_detail_index] == 0
      return unless value[:string_index_type] == string_index_type
      return unless evidence_within_parent?(value, parent:)

      rate = BigDecimal(value[:rate].to_s)
      value if rate.positive? && rate <= 1 && rate.scale <= 6
    rescue ArgumentError
      nil
    end

    def exact_tax_amount(value, expected_path:, parent:, string_index_type:, maximum:)
      return unless value.is_a?(Hash)
      return unless value[:source_provider] == STRUCTURED_SOURCE_PROVIDER
      return unless value[:source_field_path] == expected_path
      return unless value[:tax_detail_index] == 0
      return unless value[:string_index_type] == string_index_type
      return unless evidence_within_parent?(value, parent:)

      amount = exact_integer(value[:amount], maximum:)
      value.merge(amount:) if amount
    end

    def evidence_within_parent?(value, parent:)
      return false unless bounded_span?(value)
      return false unless value[:page_index].is_a?(Integer) && value[:page_index].zero?
      return false unless value[:line_index].is_a?(Integer) && value[:line_index].between?(0, MAX_LINE_INDEX)

      parent.fetch(:provider_spans).one? do |span|
        value[:provider_span_start] >= span[:provider_span_start] &&
          value[:provider_span_end] <= span[:provider_span_end]
      end
    end

    def exact_amount_evidence(value, expected_path:, string_index_type:, maximum:)
      return unless value.is_a?(Hash) && value.keys.sort == AMOUNT_EVIDENCE_KEYS.sort
      return unless value[:source_provider] == STRUCTURED_SOURCE_PROVIDER
      return unless value[:source_field_path] == expected_path
      return unless value[:page_index] == 0
      return unless value[:line_index].is_a?(Integer) && value[:line_index].between?(0, MAX_LINE_INDEX)
      return unless value[:string_index_type] == string_index_type
      return unless bounded_span?(value)

      amount = exact_integer(value[:amount], maximum:)
      value.merge(amount:) if amount
    end

    def reference_projection(candidate, maximum:)
      result = ReceiptAmountService.reference_item_extension_projection(
        reference_price_amount: candidate.dig(:reference_price, :amount),
        reference_quantity: candidate.dig(:reference_quantity, :amount),
        reference_unit_code: candidate.dig(:reference_quantity, :unit_code),
        purchased_quantity: candidate.dig(:purchased_quantity, :amount),
        purchased_unit_code: candidate.dig(:purchased_quantity, :unit_code)
      )

      exact_integer(result[:projected_amount], maximum:)
    rescue ArgumentError, NoMethodError, TypeError
      nil
    end

    def supported_index_type?(value)
      Ocr::ResponseParser::AzureStringIndexMapper::SUPPORTED_INDEX_TYPES.include?(value)
    end

    def exact_decimal(value, maximum:)
      return unless value.is_a?(String) && value.bytesize.between?(1, MAX_NUMBER_BYTES)
      return unless value.match?(EXACT_DECIMAL_PATTERN)

      decimal = BigDecimal(value)
      decimal if decimal.positive? && decimal <= maximum
    rescue ArgumentError
      nil
    end

    def exact_integer(value, maximum:)
      decimal = exact_decimal(value.to_s, maximum:)
      decimal.to_i if decimal && decimal.frac.zero?
    end

    def bounded_span?(value)
      value.is_a?(Hash) &&
        bounded_index(value[:provider_span_start]) &&
        bounded_index(value[:provider_span_end]) &&
        value[:provider_span_end] > value[:provider_span_start]
    end

    def bounded_index(value)
      value if value.is_a?(Integer) && value.between?(0, MAX_PROVIDER_SPAN)
    end

    def ranges_overlap?(left, right)
      left[:provider_span_start] < right[:provider_span_end] &&
        right[:provider_span_start] < left[:provider_span_end]
    end

    def valid_amount_limit?(value)
      value.is_a?(Integer) && value.positive? && value <= Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_AMOUNT
    end

    def result(reason, eligible: false, **attributes)
      bounded_reason = REASONS.include?(reason) ? reason : "candidate_invalid"
      Result.new(eligible:, reason: bounded_reason, **attributes)
    end
  end
end
