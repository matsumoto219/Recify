class Ocr::ResponseParser::ReferencePricingSingleStructuredItemGrossPolicy
  CONTRACT_VERSION = "reference_pricing_single_structured_item_gross_policy_v1"
  EVIDENCE_KIND = "single_item_receipt_inner_tax_summary"
  CANDIDATE_ID = "azure_items_0_reference_pricing"
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
  COMPONENT_NAMES = %i[reference_price reference_quantity purchased_quantity printed_line_total].freeze
  COMPONENT_FIELD_NAMES = {
    reference_price: "Price",
    purchased_quantity: "Quantity",
    printed_line_total: "TotalPrice"
  }.freeze
  EXACT_DECIMAL_PATTERN = /\A(?:0|[1-9]\d*)(?:\.\d+)?\z/.freeze
  MAX_NUMBER_BYTES = 64
  MAX_AMOUNT = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_AMOUNT
  MAX_PROVIDER_SPAN = Ocr::ResponseParser::MAX_REFERENCE_PRICING_PROVIDER_SPAN
  MAX_LINES = Ocr::ResponseParser::MAX_REFERENCE_PRICING_TOTAL_LINES

  Result = Data.define(
    :eligible,
    :reason,
    :reference_price_tax_inclusion,
    :evidence_kind,
    :candidate_id,
    :contract_version
  ) do
    def initialize(
      eligible:,
      reason:,
      reference_price_tax_inclusion: nil,
      evidence_kind: nil,
      candidate_id: nil
    )
      super(
        eligible: eligible == true,
        reason: reason.to_s.dup.freeze,
        reference_price_tax_inclusion: reference_price_tax_inclusion&.dup&.freeze,
        evidence_kind: evidence_kind&.dup&.freeze,
        candidate_id: candidate_id&.dup&.freeze,
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
      item_count:,
      retained_item_indexes:,
      summary_gross_evidence:,
      adjustment_count:,
      discount_count:,
      competing_tax_basis_count:,
      item_line_total_limit:
    )
      return result("amount_limit_invalid") unless valid_amount_limit?(item_line_total_limit)
      return result("receipt_scope_invalid") unless exact_single_scope?(
        item_count:,
        retained_item_indexes:
      )
      return result("conflict_present") unless no_conflicts?(
        adjustment_count:,
        discount_count:,
        competing_tax_basis_count:
      )

      evidence = exact_evidence(summary_gross_evidence)
      return result("evidence_invalid") if evidence.nil?

      candidate_metadata = exact_candidate(candidate, evidence:, maximum: item_line_total_limit)
      return result("candidate_invalid") if candidate_metadata.nil?

      projection = reference_projection(candidate, maximum: item_line_total_limit)
      return result("projection_invalid") if projection.nil?
      return result("amount_mismatch") unless amounts_match?(
        candidate:,
        evidence:,
        projection:,
        maximum: item_line_total_limit
      )

      result(
        ELIGIBLE_REASON,
        eligible: true,
        reference_price_tax_inclusion: TAX_INCLUSION,
        evidence_kind: EVIDENCE_KIND,
        candidate_id: CANDIDATE_ID
      )
    rescue EncodingError, ArgumentError, KeyError, NoMethodError, TypeError
      result("candidate_invalid")
    end

    private

    def exact_single_scope?(item_count:, retained_item_indexes:)
      item_count == 1 && retained_item_indexes == [ 0 ]
    end

    def no_conflicts?(adjustment_count:, discount_count:, competing_tax_basis_count:)
      [ adjustment_count, discount_count, competing_tax_basis_count ].all? { |value| value == 0 }
    end

    def exact_evidence(value)
      return value if value.is_a?(
        Ocr::ResponseParser::ReferencePricingSingleStructuredItemGrossEvidenceExtractor::Result
      )

      return unless value.is_a?(Hash)
      return unless value.keys.sort == %i[
        document_tax_total item_parent kind string_index_type summary_total tax_amount tax_description tax_detail_parent
      ].sort
      return unless value[:kind] == EVIDENCE_KIND

      value
    end

    def exact_candidate(candidate, evidence:, maximum:)
      return unless candidate.is_a?(Hash)
      return unless candidate[:candidate_id] == CANDIDATE_ID && candidate[:item_index] == 0
      return unless candidate[:source_kind].nil?
      return unless candidate[:validation_state] == "ambiguous"
      return unless candidate[:rejection_reasons] == [ "ambiguous_tax_inclusion" ]
      return unless candidate[:reference_price_tax_inclusion] == "unknown"
      return unless candidate[:tax_inclusion_evidence].nil?

      item_parent = evidence_value(evidence, :item_parent)
      return unless valid_parent?(
        item_parent,
        expected_path: "documents[0].fields.Items[0]",
        index_key: :item_index
      )

      COMPONENT_NAMES.each do |component_name|
        return unless valid_component?(
          candidate[component_name],
          component_name:,
          item_parent:,
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

      candidate
    end

    def valid_component?(component, component_name:, item_parent:, maximum:)
      return false unless component.is_a?(Hash)

      amount = exact_decimal(component[:amount], maximum:)
      return false if amount.nil?

      evidence = component[:evidence]
      return false unless evidence.is_a?(Hash)
      return false unless evidence[:source_provider] == SOURCE_PROVIDER
      field_names = if component_name == :reference_quantity
        reference_quantity_field_names(component, maximum:)
      else
        [ COMPONENT_FIELD_NAMES.fetch(component_name) ]
      end
      return false unless field_names.any? do |field_name|
        evidence[:source_field_path] == "documents[0].fields.Items[0].#{field_name}"
      end
      return false unless evidence[:item_index] == 0

      valid_span_within?(evidence, item_parent)
    end

    def reference_quantity_field_names(component, maximum:)
      return [ "Price" ] if component[:origin] == "explicit"
      return [] unless component[:origin] == "implicit_per_unit"
      return [] unless exact_decimal(component[:amount], maximum:) == BigDecimal("1")

      %w[Price Quantity QuantityUnit]
    end

    def exact_evidence_valid?(evidence)
      return false unless evidence_value(evidence, :kind) == EVIDENCE_KIND
      return false unless supported_index_type?(evidence_value(evidence, :string_index_type))

      item_parent = evidence_value(evidence, :item_parent)
      tax_parent = evidence_value(evidence, :tax_detail_parent)
      tax_description = evidence_value(evidence, :tax_description)
      tax_amount = evidence_value(evidence, :tax_amount)
      document_tax_total = evidence_value(evidence, :document_tax_total)
      summary_total = evidence_value(evidence, :summary_total)
      return false unless valid_parent?(
        item_parent,
        expected_path: "documents[0].fields.Items[0]",
        index_key: :item_index
      )
      return false unless valid_parent?(
        tax_parent,
        expected_path: "documents[0].fields.TaxDetails[0]",
        index_key: :tax_detail_index
      )
      return false unless ranges_disjoint?(item_parent, tax_parent)
      return false unless valid_line_evidence?(
        tax_description,
        expected_path: "documents[0].fields.TaxDetails[0].Description",
        index_type: evidence_value(evidence, :string_index_type),
        index_key: :tax_detail_index
      )
      return false unless valid_line_evidence?(
        tax_amount,
        expected_path: "documents[0].fields.TaxDetails[0].Amount",
        index_type: evidence_value(evidence, :string_index_type),
        index_key: :tax_detail_index
      )
      return false unless valid_line_evidence?(
        document_tax_total,
        expected_path: "documents[0].fields.TotalTax",
        index_type: evidence_value(evidence, :string_index_type)
      )
      return false unless valid_line_evidence?(
        summary_total,
        expected_path: nil,
        index_type: evidence_value(evidence, :string_index_type),
        source_provider: "azure_document_total"
      )
      return false unless valid_span_within?(tax_description, tax_parent)
      return false unless valid_span_within?(tax_amount, tax_parent)
      return false unless ranges_disjoint?(tax_description, tax_amount)
      return false unless ranges_equal_or_disjoint?(tax_amount, document_tax_total)
      return false unless ranges_disjoint?(summary_total, item_parent)
      return false unless ranges_disjoint?(summary_total, tax_parent)

      tax_amount_value = exact_integer(evidence_value(tax_amount, :amount), maximum: MAX_AMOUNT, positive: true)
      tax_total_value = exact_integer(
        evidence_value(document_tax_total, :amount),
        maximum: MAX_AMOUNT,
        positive: true
      )
      tax_amount_value == tax_total_value &&
        exact_integer(evidence_value(summary_total, :amount), maximum: MAX_AMOUNT, positive: true)
    end

    def valid_parent?(value, expected_path:, index_key:)
      return false unless value.is_a?(Hash)
      expected_keys = %i[
        source_provider source_field_path provider_span_start provider_span_end
      ] + [ index_key ]
      return false unless value.keys.sort == expected_keys.sort
      return false unless value[:source_provider] == SOURCE_PROVIDER
      return false unless value[:source_field_path] == expected_path
      return false unless value[index_key] == 0

      valid_span?(value)
    end

    def valid_line_evidence?(
      value,
      expected_path:,
      index_type:,
      source_provider: SOURCE_PROVIDER,
      index_key: nil
    )
      return false unless value.is_a?(Hash)

      required_keys = %i[
        source_provider source_field_path page_index line_index string_index_type
        provider_span_start provider_span_end
      ]
      required_keys << index_key if index_key
      allowed_keys = required_keys + %i[amount]
      return false unless (value.keys - allowed_keys).empty?
      return false unless required_keys.all? { |key| value.key?(key) }
      return false unless value[:source_provider] == source_provider
      return false unless value[:source_field_path].is_a?(String) && value[:source_field_path].bytesize <= 160
      return false unless value[:page_index] == 0
      return false unless value[:line_index].is_a?(Integer) && value[:line_index].between?(0, MAX_LINES - 1)
      actual_path = expected_path || "pages[0].lines[#{value[:line_index]}]"
      return false unless value[:source_field_path] == actual_path
      return false unless value[:string_index_type] == index_type
      return false if index_key && value[index_key] != 0

      valid_span?(value)
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
      result if exact_integer(amount, maximum:, positive: true)
    rescue ReceiptAmountService::InvalidItemSourceError
      nil
    end

    def amounts_match?(candidate:, evidence:, projection:, maximum:)
      return false unless exact_evidence_valid?(evidence)

      projected_amount = projection.fetch(:projected_amount)

      printed = exact_integer(
        candidate.dig(:printed_line_total, :amount),
        maximum:,
        positive: true
      )
      summary = exact_integer(
        evidence_value(evidence_value(evidence, :summary_total), :amount),
        maximum:,
        positive: true
      )
      corroboration = candidate[:corroboration]
      return false unless corroboration.is_a?(Hash)
      return false unless exact_integer(corroboration[:projected_amount], maximum:, positive: true) == projected_amount
      return false unless exact_integer(corroboration[:printed_line_total], maximum:, positive: true) == printed
      return false unless corroboration_exact_amount_valid?(
        corroboration[:exact_amount],
        projection.fetch(:exact_amount)
      )

      [ projected_amount, printed, summary ].uniq.one?
    end

    def corroboration_exact_amount_valid?(value, exact_amount)
      return false unless value.is_a?(Hash)
      return false unless value.keys.sort == %i[denominator numerator]

      value[:numerator] == exact_amount.numerator.to_s &&
        value[:denominator] == exact_amount.denominator.to_s
    end

    def exact_decimal(value, maximum:)
      return unless value.is_a?(String) && value.bytesize <= MAX_NUMBER_BYTES
      return unless value.match?(EXACT_DECIMAL_PATTERN)

      decimal = BigDecimal(value)
      decimal if decimal.positive? && decimal <= maximum
    rescue ArgumentError
      nil
    end

    def exact_integer(value, maximum:, positive:)
      return unless value.is_a?(Integer) || value.is_a?(String)

      integer = Integer(value, exception: false)
      return if integer.nil?
      return unless integer.to_s == value.to_s
      return unless integer.between?(positive ? 1 : 0, maximum)

      integer
    end

    def valid_amount_limit?(value)
      value.is_a?(Integer) && value.between?(1, MAX_AMOUNT)
    end

    def supported_index_type?(value)
      Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: value).present?
    end

    def valid_span?(value)
      return false unless value.is_a?(Hash)

      start_value = value[:provider_span_start]
      end_value = value[:provider_span_end]
      start_value.is_a?(Integer) && end_value.is_a?(Integer) &&
        start_value.between?(0, MAX_PROVIDER_SPAN) && end_value > start_value &&
        end_value <= MAX_PROVIDER_SPAN
    end

    def valid_span_within?(inner, outer)
      valid_span?(inner) && valid_span?(outer) &&
        inner[:provider_span_start] >= outer[:provider_span_start] &&
        inner[:provider_span_end] <= outer[:provider_span_end]
    end

    def ranges_disjoint?(left, right)
      valid_span?(left) && valid_span?(right) &&
        (left[:provider_span_end] <= right[:provider_span_start] ||
          right[:provider_span_end] <= left[:provider_span_start])
    end

    def ranges_equal_or_disjoint?(left, right)
      same_range = valid_span?(left) && valid_span?(right) &&
        left[:provider_span_start] == right[:provider_span_start] &&
        left[:provider_span_end] == right[:provider_span_end]
      same_range || ranges_disjoint?(left, right)
    end

    def evidence_value(value, key)
      value.respond_to?(key) ? value.public_send(key) : value[key]
    end

    def result(reason, eligible: false, **attributes)
      bounded_reason = REASONS.include?(reason) ? reason : "candidate_invalid"
      Result.new(eligible:, reason: bounded_reason, **attributes)
    end
  end
end
