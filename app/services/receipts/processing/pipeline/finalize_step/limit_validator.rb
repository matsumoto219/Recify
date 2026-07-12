class Receipts::Processing::Pipeline::FinalizeStep::LimitValidator
  def initialize(receipt:)
    @receipt = receipt
  end

  def validate_structural_limits!(params)
    validate_receipt_items_limit!(params[:receipt_items_attributes])
    validate_collection_limit!(
      name: "receipt_adjustments",
      attributes: params[:receipt_adjustments_attributes],
      limit: receipt_adjustments_limit
    )
    validate_collection_limit!(
      name: "receipt_payments",
      attributes: params[:receipt_payments_attributes],
      limit: receipt_payments_limit
    )
    validate_collection_limit!(
      name: "receipt_tax_details",
      attributes: params[:receipt_tax_details_attributes],
      limit: receipt_tax_details_limit
    )
  end

  def validate_amount_limits!(receipt_attributes:, items_attributes:, payments_attributes:, tax_details_attributes:, adjustments_attributes:)
    violation = ReceiptAmountService.violations_for(
      receipt: receipt_attributes,
      receipt_items: items_attributes,
      receipt_adjustments: adjustments_attributes,
      receipt_payments: payments_attributes,
      receipt_tax_details: tax_details_attributes
    ).first
    return if violation.blank?

    raise Receipts::Processing::AnalysisError.new(
      "analysis_value_invalid",
      "#{violation.fetch(:resource)}_amount_limit_exceeded field=#{violation.fetch(:field)} actual=#{violation.fetch(:actual_value)} limit=#{violation.fetch(:limit)}",
      metadata: amount_limit_exceeded_metadata(violation)
    )
  end

  def validate_source_structural_limits!(ocr_result:, ai_result: nil)
    validate_source_collection_limit!(
      error: "analysis_items_invalid",
      resource: "receipt_items",
      count_metadata: ocr_candidate_count_metadata(ocr_result, :items),
      limit: receipt.receipt_items_limit
    )
    validate_source_collection_limit!(
      error: "analysis_value_invalid",
      resource: "receipt_payments",
      count_metadata: ocr_candidate_count_metadata(ocr_result, :payments),
      limit: receipt_payments_limit
    )
    validate_source_collection_limit!(
      error: "analysis_value_invalid",
      resource: "receipt_tax_details",
      count_metadata: ocr_candidate_count_metadata(ocr_result, :tax_details),
      limit: receipt_tax_details_limit
    )
    validate_source_collection_limit!(
      error: "analysis_value_invalid",
      resource: "receipt_adjustments",
      count_metadata: ocr_candidate_count_metadata(ocr_result, :adjustment_candidates),
      limit: receipt_adjustments_limit
    )
    return if ai_result.blank?

    validate_source_collection_limit!(
      error: "analysis_items_invalid",
      resource: "receipt_items",
      count_metadata: ai_attribute_count_metadata(ai_result, :receipt_items_attributes),
      limit: receipt.receipt_items_limit
    )
    validate_source_collection_limit!(
      error: "analysis_value_invalid",
      resource: "receipt_adjustments",
      count_metadata: ai_attribute_count_metadata(ai_result, :receipt_adjustments_attributes),
      limit: receipt_adjustments_limit
    )
  end

  private

  attr_reader :receipt

  def validate_receipt_items_limit!(items_attributes)
    limit = receipt.receipt_items_limit
    count = Array(items_attributes).size
    raise_limit_exceeded!(
      error: "analysis_items_invalid",
      resource: "receipt_items",
      limit: limit,
      actual_count: count,
      snapshot_count: count
    )
  end

  def validate_collection_limit!(name:, attributes:, limit:)
    count = Array(attributes).size
    raise_limit_exceeded!(
      error: "analysis_value_invalid",
      resource: name,
      limit: limit,
      actual_count: count,
      snapshot_count: count
    )
  end

  def receipt_adjustments_limit
    ReceiptAdjustment.per_receipt_limit
  end

  def receipt_payments_limit
    ReceiptPayment.per_receipt_limit
  end

  def receipt_tax_details_limit
    ReceiptTaxDetail.per_receipt_limit
  end

  def validate_source_collection_limit!(error:, resource:, count_metadata:, limit:)
    actual_count = count_metadata[:actual_count]
    return if actual_count.nil?

    raise_limit_exceeded!(
      error: error,
      resource: resource,
      limit: limit,
      actual_count: actual_count,
      snapshot_count: count_metadata[:snapshot_count]
    )
  end

  def raise_limit_exceeded!(error:, resource:, limit:, actual_count:, snapshot_count: nil)
    return if actual_count <= limit

    raise Receipts::Processing::AnalysisError.new(
      error,
      "#{resource}_limit_exceeded count=#{actual_count} limit=#{limit}",
      metadata: limit_exceeded_metadata(
        error: error,
        resource: resource,
        limit: limit,
        actual_count: actual_count,
        snapshot_count: snapshot_count
      )
    )
  end

  def ocr_candidate_count_metadata(ocr_result, key)
    result = normalized_hash(ocr_result)
    counts = normalized_hash(result[:candidate_counts])
    metadata = normalize_count_metadata(counts[key])
    return metadata if metadata[:actual_count]

    values = Array(normalized_hash(result[:candidates])[key])
    { actual_count: values.size, snapshot_count: values.size }
  end

  def ai_attribute_count_metadata(ai_result, key)
    result = normalized_hash(ai_result)
    counts = normalized_hash(result[:attribute_counts])
    metadata = normalize_count_metadata(counts[key])
    return metadata if metadata[:actual_count]

    values = Array(result[key])
    { actual_count: values.size, snapshot_count: values.size }
  end

  def normalize_count_metadata(value)
    if value.respond_to?(:to_h)
      metadata = value.to_h.with_indifferent_access
      return {
        actual_count: normalize_count(metadata[:actual_count]),
        snapshot_count: normalize_count(metadata[:snapshot_count])
      }
    end

    count = normalize_count(value)
    { actual_count: count, snapshot_count: count }
  end

  def normalize_count(value)
    Integer(value, exception: false)
  end

  def limit_exceeded_metadata(error:, resource:, limit:, actual_count:, snapshot_count: nil)
    {
      error: error,
      resource: resource,
      limit: limit,
      actual_count: actual_count,
      snapshot_count: snapshot_count
    }.compact
  end

  def amount_limit_exceeded_metadata(violation)
    {
      error: "analysis_value_invalid",
      resource: violation.fetch(:resource),
      field: violation.fetch(:field),
      limit: violation.fetch(:limit),
      actual_value: violation.fetch(:actual_value),
      index: violation[:index]
    }.compact
  end

  def normalized_hash(value)
    return value.with_indifferent_access if value.respond_to?(:with_indifferent_access)

    {}.with_indifferent_access
  end
end
