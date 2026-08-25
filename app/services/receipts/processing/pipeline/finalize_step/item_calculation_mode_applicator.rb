class Receipts::Processing::Pipeline::FinalizeStep::ItemCalculationModeApplicator
  DECISION_CONTRACT = Receipts::Processing::Contracts::ItemCalculationModeDecision
  PROPOSAL_CONTRACT = Receipts::Processing::Contracts::ItemCalculationModeProposalSet
  SUPPORTED_PRICING_SOURCE_KINDS = %w[count_unit_price explicit_line_total].freeze
  REFERENCE_SOURCE_FIELDS = %i[
    reference_price_amount
    reference_quantity
    reference_quantity_unit_code
    reference_quantity_unit_raw
    reference_price_tax_inclusion
  ].freeze
  AMOUNT_REVIEW_FIELDS = %i[
    needs_review
    inconsistencies
    blocking_inconsistencies
    warning_inconsistencies
    warning_reasons
    mismatch_codes
    blocking_mismatch_codes
    warning_mismatch_codes
    review_reasons
  ].freeze
  COMPUTED_RECEIPT_FIELDS = %i[
    adjustment_discount_total
    adjustment_surcharge_total
    payment_adjustment_total
    adjustment_tax_rate_missing_total
    adjusted_item_total
    subtotal
    tax
    total
    tax_rate
    item_amount_basis
    tax_detail_amount_basis
    purchase_total
    final_payment_total
    purchase_adjustment_total
    payment_amount_sum
    tax_rate_groups
  ].freeze
  COMPUTED_ITEM_FIELDS = %i[
    quantity
    quantity_unit_code
    original_line_total
    line_total
    discount_amount
    discount_rate
    tax_rate
  ].freeze
  SKIPPED_SELECTION = Object.new.freeze
  private_constant :SKIPPED_SELECTION

  Selection = Data.define(
    :item_identity,
    :item_index,
    :position_index,
    :proposal_id,
    :pricing_source_kind,
    :price,
    :quantity,
    :quantity_unit_code,
    :explicit_line_total,
    :projected_line_total
  ) do
    def initialize(
      item_identity:,
      item_index:,
      position_index:,
      proposal_id:,
      pricing_source_kind:,
      price: nil,
      quantity: nil,
      quantity_unit_code: nil,
      explicit_line_total: nil,
      projected_line_total:
    )
      super(
        item_identity: item_identity.dup.freeze,
        item_index: item_index,
        position_index: position_index,
        proposal_id: proposal_id.dup.freeze,
        pricing_source_kind: pricing_source_kind.dup.freeze,
        price: price,
        quantity: quantity,
        quantity_unit_code: quantity_unit_code&.dup&.freeze,
        explicit_line_total: explicit_line_total,
        projected_line_total: projected_line_total
      )
    end
  end

  Result = Data.define(:params, :amount_result, :decisions, :selections) do
    def applied?
      selections.any?
    end
  end

  class << self
    def call(
      params:,
      ocr_result:,
      preliminary_amount_result:,
      automatic_application_allowed:,
      item_price_limit:,
      item_line_total_limit:,
      &amount_calculator
    )
      new(
        params:,
        ocr_result:,
        preliminary_amount_result:,
        automatic_application_allowed:,
        item_price_limit:,
        item_line_total_limit:,
        amount_calculator:
      ).call
    end
  end

  def initialize(
    params:,
    ocr_result:,
    preliminary_amount_result:,
    automatic_application_allowed:,
    item_price_limit:,
    item_line_total_limit:,
    amount_calculator:
  )
    @params = params
    @ocr_result = ocr_result
    @preliminary_amount_result = preliminary_amount_result
    @automatic_application_allowed = automatic_application_allowed == true
    @item_price_limit = item_price_limit
    @item_line_total_limit = item_line_total_limit
    @amount_calculator = amount_calculator
  end

  def call
    return unchanged_result unless automatic_application_allowed
    return unchanged_result unless amount_calculator.respond_to?(:call)

    decision_batch = decision_batch_for
    return unchanged_result unless decision_batch

    proposals = decision_batch.proposals
    decisions = decision_batch.decisions

    selections = selections_for(decisions, proposals)
    return unchanged_result(decisions:) if selections.nil? || selections.empty?

    candidate_params = params.deep_dup
    apply_selections!(candidate_params, selections)
    final_amount_result = amount_calculator.call(candidate_params)
    return unchanged_result(decisions:) unless final_result_valid?(
      candidate_params,
      final_amount_result,
      selections
    )

    Result.new(
      params: candidate_params,
      amount_result: final_amount_result,
      decisions: decisions.freeze,
      selections: selections.freeze
    )
  rescue ReceiptAmountService::InvalidItemSourceError,
    ArgumentError,
    EncodingError,
    KeyError,
    TypeError
    unchanged_result
  end

  private

  attr_reader :params,
    :ocr_result,
    :preliminary_amount_result,
    :automatic_application_allowed,
    :item_price_limit,
    :item_line_total_limit,
    :amount_calculator

  def decision_batch_for
    proposals = normalized_hash(normalized_hash(ocr_result)[:adoption_proposals])[:item_calculation_modes]

    DECISION_CONTRACT.evaluate_all(
      item_proposals: proposals,
      ocr_snapshot: ocr_result,
      count_tax_semantics: count_tax_semantics,
      item_price_limit:,
      item_line_total_limit:
    )
  end

  def count_tax_semantics
    profile = normalized_hash(preliminary_amount_result[:calculation_profile])
    computed = normalized_hash(preliminary_amount_result[:computed])
    amount_engine = normalized_hash(preliminary_amount_result[:amount_engine])
    selected_status = preliminary_amount_result[:selected_candidate_status].to_s

    return "unknown" unless profile[:receipt_tax_basis].to_s == "total_includes_tax"
    return "unknown" unless profile[:item_amount_basis].to_s == "line_total_as_recorded"
    return "unknown" unless computed[:item_amount_basis].to_s == "line_total_as_recorded"
    return "unknown" unless selected_status == "accepted"
    return "unknown" unless amount_engine[:no_safe_candidate] == false

    "reproducible_as_recorded"
  end

  def selections_for(decisions, proposals)
    items = Array(params[:receipt_items_attributes])
    items_by_identity = items.each_with_index.each_with_object({}) do |(item, index), result|
      identity = normalized_hash(item)[:ocr_item_identity]
      next if identity.blank?

      (result[identity] ||= []) << [ index, item ]
    end
    proposals_by_identity = proposals.index_by { |proposal| proposal.fetch("item_identity") }

    selections = decisions.each_with_object([]) do |decision, result|
      next unless decision.confirmed?
      next unless SUPPORTED_PRICING_SOURCE_KINDS.include?(decision.selected_pricing_source_kind)

      matches = items_by_identity[decision.item_identity]
      return nil unless matches&.one?

      proposal = proposals_by_identity[decision.item_identity]
      return nil unless proposal

      selection = selection_for(decision, proposal, *matches.sole)
      return nil if selection.nil?

      result << selection unless selection.equal?(SKIPPED_SELECTION)
    end
    return nil unless valid_selection_positions?(selections)

    selections
  end

  def valid_selection_positions?(selections)
    positions = selections.map(&:position_index)

    positions.all? do |position|
      position.is_a?(Integer) && position.between?(1, PROPOSAL_CONTRACT::MAX_SETS)
    end && positions.uniq.size == positions.size
  end

  def selection_for(decision, proposal, item_index, item)
    attributes = normalized_hash(item)
    return SKIPPED_SELECTION if existing_source_metadata?(attributes)
    return SKIPPED_SELECTION if discount_source_present?(attributes)
    return SKIPPED_SELECTION if Array(proposal["conflicts"]).include?("discount")

    options = proposal.fetch("options").select do |option|
      option["proposal_id"] == decision.selected_proposal_id &&
        option["pricing_source_kind"] == decision.selected_pricing_source_kind
    end
    return unless options.one?

    option = options.sole
    case decision.selected_pricing_source_kind
    when "count_unit_price"
      count_selection(decision, option, attributes, item_index:)
    when "explicit_line_total"
      explicit_selection(decision, option, attributes, item_index:)
    end
  end

  def count_selection(decision, option, attributes, item_index:)
    source = option.fetch("source")
    price = exact_integer(source.fetch("price_amount"))
    quantity = exact_positive_integer(source.fetch("quantity"))
    unit_code = canonical_countable_unit(source.fetch("quantity_unit_code"))
    return if [ price, quantity, unit_code ].any?(&:nil?)
    return unless exact_integer_matches?(attributes[:price], price)
    return unless exact_integer_matches?(attributes[:quantity], quantity)
    return unless attributes[:quantity_unit_code] == unit_code
    return unless attributes[:quantity_unit_raw].nil?

    Selection.new(
      item_identity: decision.item_identity,
      item_index:,
      position_index: attributes[:position_index],
      proposal_id: decision.selected_proposal_id,
      pricing_source_kind: decision.selected_pricing_source_kind,
      price:,
      quantity: BigDecimal(quantity.to_s),
      quantity_unit_code: unit_code,
      projected_line_total: decision.projected_line_total
    )
  end

  def explicit_selection(decision, option, attributes, item_index:)
    source = option.fetch("source")
    line_total = exact_integer(source.fetch("line_total_amount"))
    return if line_total.nil?
    return unless exact_integer_matches?(attributes[:original_line_total], line_total)
    return unless exact_integer_matches?(attributes[:line_total], line_total)

    Selection.new(
      item_identity: decision.item_identity,
      item_index:,
      position_index: attributes[:position_index],
      proposal_id: decision.selected_proposal_id,
      pricing_source_kind: decision.selected_pricing_source_kind,
      explicit_line_total: line_total,
      projected_line_total: decision.projected_line_total
    )
  end

  def existing_source_metadata?(attributes)
    attributes[:pricing_source_kind].present? ||
      REFERENCE_SOURCE_FIELDS.any? { |field| !attributes[field].nil? }
  end

  def discount_source_present?(attributes)
    !attributes[:discount_amount].nil? || !attributes[:discount_rate].nil?
  end

  def apply_selections!(candidate_params, selections)
    items = Array(candidate_params[:receipt_items_attributes])
    selections.each do |selection|
      item = items.fetch(selection.item_index)
      clear_reference_source_fields!(item)
      item[:pricing_source_kind] = selection.pricing_source_kind
      if selection.pricing_source_kind == "count_unit_price"
        item[:price] = selection.price
        item[:quantity] = selection.quantity
        item[:quantity_unit_code] = selection.quantity_unit_code
        item[:quantity_unit_raw] = nil
      else
        item[:price] = nil
      end
    end
  end

  def clear_reference_source_fields!(item)
    REFERENCE_SOURCE_FIELDS.each { |field| item[field] = nil }
  end

  def final_result_valid?(candidate_params, final_amount_result, selections)
    return false unless final_amount_result.is_a?(Hash)
    return false unless Array(candidate_params[:receipt_items_attributes]).size ==
      Array(params[:receipt_items_attributes]).size
    return false unless financial_result_signature(final_amount_result) ==
      financial_result_signature(preliminary_amount_result)
    return false unless unselected_computed_prices_unchanged?(final_amount_result, selections)

    computed_items = Array(final_amount_result.dig(:computed, :items))
    selections.all? do |selection|
      item = normalized_hash(computed_items[selection.item_index])
      next false unless exact_integer_matches?(item[:original_line_total], selection.projected_line_total)
      next false unless exact_integer_matches?(item[:line_total], selection.projected_line_total)

      if selection.pricing_source_kind == "count_unit_price"
        exact_integer_matches?(item[:price], selection.price) &&
          exact_integer_matches?(item[:quantity], selection.quantity.to_i) &&
          item[:quantity_unit_code] == selection.quantity_unit_code
      else
        item[:price].nil?
      end
    end
  end

  def unselected_computed_prices_unchanged?(final_amount_result, selections)
    preliminary_items = Array(preliminary_amount_result.dig(:computed, :items))
    final_items = Array(final_amount_result.dig(:computed, :items))
    return false unless preliminary_items.size == final_items.size

    selected_indexes = selections.to_h { |selection| [ selection.item_index, true ] }
    preliminary_items.each_index.all? do |index|
      selected_indexes[index] ||
        normalized_hash(preliminary_items[index])[:price] == normalized_hash(final_items[index])[:price]
    end
  end

  def financial_result_signature(result)
    computed = normalized_hash(result[:computed])

    {
      calculation_profile: normalized_hash(result[:calculation_profile]).slice(
        :tax_rounding_mode,
        :discount_rounding_mode,
        :receipt_tax_basis,
        :item_amount_basis
      ),
      resolved: normalized_hash(result[:resolved]).slice(:subtotal, :tax, :total, :tax_rate),
      tax_details: result[:tax_details],
      computed_receipt: computed.slice(*COMPUTED_RECEIPT_FIELDS),
      computed_items: Array(computed[:items]).map do |item|
        normalized_hash(item).slice(*COMPUTED_ITEM_FIELDS)
      end,
      review: AMOUNT_REVIEW_FIELDS.to_h { |field| [ field, result[field] ] },
      selected_candidate_status: result[:selected_candidate_status],
      no_safe_candidate: normalized_hash(result[:amount_engine])[:no_safe_candidate]
    }
  end

  def exact_integer(value)
    return unless value.is_a?(String)
    return unless value.bytesize <= PROPOSAL_CONTRACT::MAX_EXACT_NUMBER_BYTES
    return unless value.match?(PROPOSAL_CONTRACT::EXACT_INTEGER_PATTERN)

    Integer(value, 10)
  rescue ArgumentError
    nil
  end

  def exact_positive_integer(value)
    integer = exact_integer(value)
    integer if integer&.positive? && integer <= PROPOSAL_CONTRACT::MAX_QUANTITY
  end

  def exact_integer_matches?(value, expected)
    decimal = BigDecimal(value.to_s)
    decimal.finite? && decimal.frac.zero? && decimal.to_i == expected
  rescue ArgumentError, TypeError
    false
  end

  def canonical_countable_unit(value)
    unit = ReceiptQuantityUnit.unit_for(value)
    value if value.is_a?(String) && unit&.code == value && unit.kind == :countable
  end

  def normalized_hash(value)
    value.respond_to?(:with_indifferent_access) ? value.with_indifferent_access : {}.with_indifferent_access
  end

  def unchanged_result(decisions: [])
    Result.new(
      params: params,
      amount_result: preliminary_amount_result,
      decisions: Array(decisions).freeze,
      selections: [].freeze
    )
  end
end
