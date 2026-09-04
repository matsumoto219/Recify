require "set"

class Ocr::ResponseParser::ReferencePricingStructuredItemQuantityOverlay
  MAX_ITEMS = Ocr::ResponseParser::ItemCalculationModeCandidateExtractor::MAX_ITEMS
  MAX_ITEM_SPANS = 16
  MAX_PROVIDER_SPAN_VALUE = 10_000_000
  SUPPORTED_MODEL_ID = Ocr::ResponseParser::ItemCalculationModeCandidateExtractor::SUPPORTED_MODEL_ID
  SUPPORTED_API_VERSION = Ocr::ResponseParser::ItemCalculationModeCandidateExtractor::SUPPORTED_API_VERSION
  SOURCE_PROVIDER = "azure_structured"
  AGGREGATE_MEMBER_EVIDENCE_KIND = "structured_items_receipt_inner_tax_summary_member"

  def self.call(
    analyze_result:,
    profile:,
    items:,
    reference_pricing_candidates:,
    item_calculation_mode_candidates:,
    excluded_item_indexes:
  )
    new(
      analyze_result:,
      profile:,
      items:,
      reference_pricing_candidates:,
      item_calculation_mode_candidates:,
      excluded_item_indexes:
    ).call
  end

  def initialize(
    analyze_result:,
    profile:,
    items:,
    reference_pricing_candidates:,
    item_calculation_mode_candidates:,
    excluded_item_indexes:
  )
    @analyze_result = analyze_result
    @items = items
    @references = Array(reference_pricing_candidates)
    @carriers = Array(item_calculation_mode_candidates)
    @excluded_item_indexes = Array(excluded_item_indexes).to_set
    @profile = profile
  end

  def call
    return {} unless inputs_bounded?

    references_by_index = references.group_by { |candidate| candidate[:item_index] if candidate.is_a?(Hash) }
    carriers_by_index = carriers.group_by { |candidate| candidate[:item_index] if candidate.is_a?(Hash) }
    overlays = references_by_index.each_with_object({}) do |(item_index, candidates), result|
      next unless item_index.is_a?(Integer) && item_index.between?(0, items.size - 1)
      next if excluded_item_indexes.include?(item_index)
      next unless candidates.one? && carriers_by_index.fetch(item_index, []).one?

      overlay = overlay_for(
        item: items.fetch(item_index),
        item_index:,
        candidate: candidates.sole,
        carrier: carriers_by_index.fetch(item_index).sole
      )
      result[item_index] = overlay if overlay
    end

    reject_partial_aggregate(overlays)
  rescue ArgumentError, KeyError, NoMethodError, TypeError
    {}
  end

  private

  attr_reader :analyze_result, :carriers, :excluded_item_indexes, :items, :profile, :references

  def inputs_bounded?
    analyze_result.is_a?(Hash) && items.is_a?(Array) && items.size <= MAX_ITEMS &&
      references.size <= MAX_ITEMS && carriers.size <= MAX_ITEMS && supported_provider_context?
  end

  def supported_provider_context?
    return false unless analyze_result["modelId"] == SUPPORTED_MODEL_ID
    return false unless analyze_result["apiVersion"] == SUPPORTED_API_VERSION

    mapper = Ocr::ResponseParser::AzureStringIndexMapper.build(index_type: analyze_result["stringIndexType"])
    mapper&.index_type == analyze_result["stringIndexType"]
  end

  def overlay_for(item:, item_index:, candidate:, carrier:)
    return unless candidate[:source_kind].nil?
    return unless candidate[:candidate_id] == reference_candidate_id(item_index)
    return unless candidate[:validation_state] == "valid" && Array(candidate[:rejection_reasons]).empty?
    return unless carrier_valid?(carrier, item_index:)

    parent_spans = item_parent_spans(item)
    return if parent_spans.nil?

    parent_range = parent_spans.first.begin...parent_spans.last.end
    return unless carrier_parent_valid?(carrier, item_index:, parent_range:)
    return unless destination_evidence_valid?(carrier[:destination_evidence], item_index:, parent_spans:)
    return unless reference_evidence_valid?(candidate, item_index:, parent_spans:)

    purchased = candidate[:purchased_quantity]
    return unless purchased.is_a?(Hash) && purchased[:unit_status] == "known"
    amount = decimal(purchased[:amount])
    return unless amount&.positive? && quantity_matches?(item, amount)
    return unless measurement_unit_valid?(candidate, purchased[:unit_code])
    return unless countable_provider_unit?(item)

    {
      amount: purchased[:amount],
      unit_code: purchased[:unit_code],
      unit_status: purchased[:unit_status]
    }
  end

  def carrier_valid?(carrier, item_index:)
    carrier.is_a?(Hash) &&
      carrier[:candidate_id] == "azure_items_#{item_index}_item_calculation_mode" &&
      carrier[:item_index] == item_index && carrier[:source_provider] == SOURCE_PROVIDER &&
      carrier[:source_field_path] == item_path(item_index) &&
      carrier[:provider_model_id] == analyze_result["modelId"] &&
      carrier[:provider_api_version] == analyze_result["apiVersion"] &&
      carrier[:string_index_type] == analyze_result["stringIndexType"]
  end

  def carrier_parent_valid?(carrier, item_index:, parent_range:)
    carrier[:provider_span_start] == parent_range.begin &&
      carrier[:provider_span_end] == parent_range.end &&
      carrier[:item_identity] ==
        "azure_structured_item_i#{item_index}_s#{parent_range.begin}_e#{parent_range.end}"
  end

  def item_parent_spans(item)
    spans = item.is_a?(Hash) ? item["spans"] : nil
    return unless spans.is_a?(Array) && spans.size.between?(1, MAX_ITEM_SPANS)

    ranges = spans.map do |span|
      return unless span.is_a?(Hash)

      offset = span["offset"]
      length = span["length"]
      return unless offset.is_a?(Integer) && length.is_a?(Integer) && length.positive?
      return unless offset.between?(0, MAX_PROVIDER_SPAN_VALUE)
      return unless length <= MAX_PROVIDER_SPAN_VALUE - offset

      offset...(offset + length)
    end
    return unless ranges.each_cons(2).all? { |left, right| left.end <= right.begin }

    ranges
  end

  def destination_evidence_valid?(evidence, item_index:, parent_spans:)
    return false unless evidence.is_a?(Hash)
    return false unless evidence[:source_field_path] == "#{item_path(item_index)}.Description"

    evidence_range_within_parent?(evidence, parent_spans:)
  end

  def reference_evidence_valid?(candidate, item_index:, parent_spans:)
    path = item_path(item_index)
    components = {
      reference_price: [ "#{path}.Price" ],
      reference_quantity: [ "#{path}.Price", "#{path}.Quantity" ],
      purchased_quantity: [ "#{path}.Quantity" ],
      printed_line_total: [ "#{path}.TotalPrice" ]
    }

    components.all? do |component, allowed_paths|
      component_evidence_valid?(
        candidate.dig(component, :evidence),
        item_index:,
        parent_spans:,
        allowed_paths:
      )
    end
  end

  def component_evidence_valid?(evidence, item_index:, parent_spans:, allowed_paths:)
    evidence.is_a?(Hash) && evidence[:source_provider] == SOURCE_PROVIDER &&
      evidence[:item_index] == item_index && allowed_paths.include?(evidence[:source_field_path]) &&
      evidence_range_within_parent?(evidence, parent_spans:)
  end

  def evidence_range_within_parent?(evidence, parent_spans:)
    span_start = evidence[:provider_span_start]
    span_end = evidence[:provider_span_end]
    span_start.is_a?(Integer) && span_end.is_a?(Integer) &&
      span_end > span_start && parent_spans.any? do |parent_span|
        span_start >= parent_span.begin && span_end <= parent_span.end
      end
  end

  def quantity_matches?(item, candidate_amount)
    quantity = item.dig("valueObject", "Quantity")
    quantity.is_a?(Hash) && quantity.key?("valueNumber") &&
      decimal(quantity["valueNumber"]) == candidate_amount
  end

  def measurement_unit_valid?(candidate, unit_code)
    unit = ReceiptQuantityUnit.unit_for(unit_code)
    unit&.kind == :decimal && unit.allows_pricing_role?(:purchased) &&
      ReceiptQuantityUnit.convertible?(
        from: unit_code,
        to: candidate.dig(:reference_quantity, :unit_code)
      )
  end

  def countable_provider_unit?(item)
    resolution = profile.resolve_quantity_unit(item.dig("valueObject", "QuantityUnit", "valueString"))
    resolution.known? && ReceiptQuantityUnit.countable?(resolution.code)
  end

  def reject_partial_aggregate(overlays)
    aggregate_candidates = references.select do |candidate|
      candidate.is_a?(Hash) && candidate.dig(:tax_inclusion_evidence, :kind) == AGGREGATE_MEMBER_EVIDENCE_KIND
    end
    indexes = aggregate_candidates.filter_map { |candidate| candidate[:item_index] }
    return overlays if indexes.empty?
    return overlays if indexes.uniq.size == aggregate_candidates.size && indexes.all? { |index| overlays.key?(index) }

    overlays.except(*indexes)
  end

  def reference_candidate_id(item_index)
    "azure_items_#{item_index}_reference_pricing"
  end

  def item_path(item_index)
    "documents[0].fields.Items[#{item_index}]"
  end

  def decimal(value)
    return unless value.is_a?(String) || value.is_a?(Numeric)
    return if value.is_a?(Float) && !value.finite?

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end
end
