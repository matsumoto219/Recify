class Receipts::Processing::Pipeline::FinalizeStep::ItemCalculationModeApplicator
  DECISION_CONTRACT = Receipts::Processing::Contracts::ItemCalculationModeDecision
  PROPOSAL_CONTRACT = Receipts::Processing::Contracts::ItemCalculationModeProposalSet
  GATE_CONTRACT = Receipts::Processing::Contracts::ReferencePricingAutoAdoptionGateSnapshot
  ITEM_PRICING_MODE_REVIEW_REASON = "item_pricing_mode_uncertain"
  SUPPORTED_PRICING_SOURCE_KINDS = %w[
    count_unit_price
    reference_quantity_price
    explicit_line_total
  ].freeze
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
  COMPUTED_ITEM_INVARIANT_FIELDS = (COMPUTED_ITEM_FIELDS + [ :price ]).freeze
  NO_TOTAL_STABLE_COMPUTED_RECEIPT_FIELDS = %i[
    adjustment_discount_total
    adjustment_surcharge_total
    payment_adjustment_total
    adjustment_tax_rate_missing_total
    tax_rate
    item_amount_basis
    tax_detail_amount_basis
    purchase_adjustment_total
    payment_amount_sum
  ].freeze
  NO_TOTAL_STABLE_SELECTED_ITEM_FIELDS = %i[
    discount_amount
    discount_rate
    tax_rate
  ].freeze
  NO_TOTAL_ALLOWED_REMOVED_REVIEW_VALUES = {
    inconsistencies: %w[insufficient_data].freeze,
    blocking_inconsistencies: %w[insufficient_data].freeze,
    mismatch_codes: %w[INSUFFICIENT_DATA].freeze,
    blocking_mismatch_codes: %w[INSUFFICIENT_DATA].freeze,
    review_reasons: %w[insufficient_data].freeze
  }.freeze
  RESOLVED_ITEM_TOTAL_ALLOWED_REMOVED_REVIEW_VALUES = {
    inconsistencies: %w[item_total_mismatch].freeze,
    blocking_inconsistencies: %w[item_total_mismatch].freeze,
    mismatch_codes: %w[ITEM_TOTAL_MISMATCH].freeze,
    blocking_mismatch_codes: %w[ITEM_TOTAL_MISMATCH].freeze,
    review_reasons: %w[item_total_mismatch].freeze
  }.freeze
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
    :reference_price_amount,
    :reference_quantity,
    :reference_quantity_unit_code,
    :reference_price_tax_inclusion,
    :explicit_line_total,
    :printed_line_total,
    :original_line_total,
    :discount_amount,
    :discount_rate,
    :projected_line_total,
    :review_reason
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
      reference_price_amount: nil,
      reference_quantity: nil,
      reference_quantity_unit_code: nil,
      reference_price_tax_inclusion: nil,
      explicit_line_total: nil,
      printed_line_total: nil,
      original_line_total: nil,
      discount_amount: nil,
      discount_rate: nil,
      projected_line_total:,
      review_reason: nil
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
        reference_price_amount: reference_price_amount,
        reference_quantity: reference_quantity,
        reference_quantity_unit_code: reference_quantity_unit_code&.dup&.freeze,
        reference_price_tax_inclusion: reference_price_tax_inclusion&.dup&.freeze,
        explicit_line_total: explicit_line_total,
        printed_line_total: printed_line_total,
        original_line_total: original_line_total,
        discount_amount: discount_amount,
        discount_rate: discount_rate,
        projected_line_total: projected_line_total,
        review_reason: review_reason&.dup&.freeze
      )
    end

    def reviewable?
      review_reason == ITEM_PRICING_MODE_REVIEW_REASON
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
      reference_pricing_gate_result: nil,
      item_price_limit:,
      item_line_total_limit:,
      &amount_calculator
    )
      new(
        params:,
        ocr_result:,
        preliminary_amount_result:,
        automatic_application_allowed:,
        reference_pricing_gate_result:,
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
    reference_pricing_gate_result:,
    item_price_limit:,
    item_line_total_limit:,
    amount_calculator:
  )
    @params = params
    @ocr_result = ocr_result
    @preliminary_amount_result = preliminary_amount_result
    @automatic_application_allowed = automatic_application_allowed == true
    @reference_pricing_gate_result = reference_pricing_gate_result
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
    :reference_pricing_gate_result,
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

    return "unknown" unless %w[total_includes_tax tax_added_to_subtotal].include?(profile[:receipt_tax_basis].to_s)
    return "unknown" unless selected_status == "accepted"
    return "unknown" unless amount_engine[:no_safe_candidate] == false
    return "reproducible_uniform_net" if uniform_net_profile?(preliminary_amount_result)
    return "unknown" unless profile[:item_amount_basis].to_s == "line_total_as_recorded"
    return "unknown" unless computed[:item_amount_basis].to_s == "line_total_as_recorded"

    "reproducible_as_recorded"
  end

  def uniform_net_profile?(amount_result)
    profile = normalized_hash(amount_result[:calculation_profile])
    computed = normalized_hash(amount_result[:computed])

    profile[:receipt_tax_basis].to_s == "tax_added_to_subtotal" &&
      computed[:receipt_tax_basis].to_s == "tax_added_to_subtotal" &&
      profile[:item_amount_basis].to_s == "line_total_as_net" &&
      computed[:item_amount_basis].to_s == "line_total_as_net" &&
      computed[:tax_detail_amount_basis].to_s == "net"
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
      next unless decision.confirmed? || decision.reviewable?
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
      position.is_a?(Integer) && position.between?(0, PROPOSAL_CONTRACT::MAX_SETS)
    end && positions.uniq.size == positions.size
  end

  def selection_for(decision, proposal, item_index, item)
    attributes = normalized_hash(item)
    return SKIPPED_SELECTION if existing_source_metadata?(attributes)

    options = proposal.fetch("options").select do |option|
      option["proposal_id"] == decision.selected_proposal_id &&
        option["pricing_source_kind"] == decision.selected_pricing_source_kind
    end
    return unless options.one?

    option = options.sole
    unless option.key?("discount")
      return SKIPPED_SELECTION if discount_source_present?(attributes)
      return SKIPPED_SELECTION if Array(proposal["conflicts"]).include?("discount")
    end
    review_reason = decision.reviewable? ? ITEM_PRICING_MODE_REVIEW_REASON : nil
    case decision.selected_pricing_source_kind
    when "count_unit_price"
      count_selection(decision, option, attributes, item_index:, review_reason:)
    when "reference_quantity_price"
      return SKIPPED_SELECTION unless reference_selection_authorized?(decision, proposal)

      reference_selection(decision, proposal, option, attributes, item_index:, review_reason:)
    when "explicit_line_total"
      explicit_selection(decision, option, attributes, item_index:, review_reason:)
    end
  end

  def reference_selection_authorized?(decision, proposal)
    gate = reference_pricing_gate_result
    return false unless gate.is_a?(Receipts::Processing::ReferencePricingAutoAdoptionFence::Result) && gate.enabled?
    return reference_item_set_authorized?(gate) if gate.binding_kind == GATE_CONTRACT::ITEM_SET_BINDING_KIND

    gate.binding_kind == GATE_CONTRACT::STRUCTURED_ITEM_BINDING_KIND &&
      gate.candidate_identity == decision.candidate_id &&
      gate.destination_identity == decision.item_identity &&
      gate.selected_proposal_identity == decision.selected_proposal_id &&
      gate.proposal_checksum == proposal["integrity_checksum"]
  end

  def reference_item_set_authorized?(gate)
    return @reference_item_set_authorized if defined?(@reference_item_set_authorized)

    binding = GATE_CONTRACT.proposal_binding_for(ocr_snapshot: ocr_result, receipt_lock_version: 0)
    @reference_item_set_authorized = binding.is_a?(Hash) &&
      binding["binding_kind"] == GATE_CONTRACT::ITEM_SET_BINDING_KIND &&
      binding["proposal_checksum"] == gate.proposal_checksum
  end

  def reference_selection(decision, proposal, option, attributes, item_index:, review_reason:)
    source = option.fetch("source")
    reference_price = exact_decimal(
      source.fetch("reference_price_amount"),
      maximum: ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX,
      maximum_scale: ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX_SCALE,
      allow_zero: true
    )
    reference_quantity = exact_decimal(
      source.fetch("reference_quantity"),
      maximum: ReceiptItem::REFERENCE_QUANTITY_MAX,
      maximum_scale: ReceiptItem::REFERENCE_QUANTITY_MAX_SCALE,
      allow_zero: false
    )
    purchased_quantity = exact_decimal(
      source.fetch("purchased_quantity"),
      maximum: ReceiptItem::REFERENCE_QUANTITY_MAX,
      maximum_scale: ReceiptItem::REFERENCE_QUANTITY_MAX_SCALE,
      allow_zero: false
    )
    reference_unit = canonical_unit(source.fetch("reference_quantity_unit_code"))
    purchased_unit = canonical_unit(source.fetch("purchased_quantity_unit_code"))
    return if [ reference_price, reference_quantity, purchased_quantity, reference_unit, purchased_unit ].any?(&:nil?)
    return unless ReceiptQuantityUnit.convertible?(from: purchased_unit, to: reference_unit)
    return unless source["reference_price_tax_inclusion"] == "gross"
    return unless exact_decimal_matches?(attributes[:price], reference_price)
    return unless exact_decimal_matches?(attributes[:quantity], purchased_quantity)
    return unless attributes[:quantity_unit_code] == purchased_unit
    return unless attributes[:quantity_unit_raw].nil?

    printed_line_total = exact_printed_line_total(proposal, projected: decision.projected_line_total)
    return if proposal["printed_line_total"] && printed_line_total.nil?
    if printed_line_total
      return unless exact_integer_matches?(attributes[:original_line_total], printed_line_total)
      return unless exact_integer_matches?(attributes[:line_total], printed_line_total)
    else
      return unless attributes[:original_line_total].nil? && attributes[:line_total].nil?
    end

    Selection.new(
      item_identity: decision.item_identity,
      item_index:,
      position_index: attributes[:position_index],
      proposal_id: decision.selected_proposal_id,
      pricing_source_kind: decision.selected_pricing_source_kind,
      quantity: purchased_quantity,
      quantity_unit_code: purchased_unit,
      reference_price_amount: reference_price,
      reference_quantity:,
      reference_quantity_unit_code: reference_unit,
      reference_price_tax_inclusion: "gross",
      printed_line_total:,
      projected_line_total: decision.projected_line_total,
      review_reason:
    )
  rescue ReceiptQuantityUnit::ConversionError
    nil
  end

  def exact_printed_line_total(proposal, projected:)
    printed = proposal["printed_line_total"]
    return if printed.nil?

    amount = exact_integer(printed["amount"])
    amount if amount == projected
  end

  def count_selection(decision, option, attributes, item_index:, review_reason:)
    source = option.fetch("source")
    price = exact_integer(source.fetch("price_amount"))
    quantity = exact_positive_integer(source.fetch("quantity"))
    unit_code = canonical_countable_unit(source.fetch("quantity_unit_code"))
    return if [ price, quantity, unit_code ].any?(&:nil?)
    return unless exact_integer_matches?(attributes[:price], price)
    return unless exact_integer_matches?(attributes[:quantity], quantity)
    return unless attributes[:quantity_unit_code] == unit_code
    return unless attributes[:quantity_unit_raw].nil?

    discount = normalized_hash(option["discount"])
    projection_arguments = {
      price_amount: source.fetch("price_amount"),
      purchased_quantity: source.fetch("quantity"),
      purchased_unit_code: unit_code
    }
    if option.key?("discount")
      return unless exact_integer_matches?(attributes[:discount_amount], exact_integer(discount["amount"]))
      return unless exact_decimal_matches?(attributes[:discount_rate], BigDecimal(discount["rate"]))

      projection_arguments[:discount_amount] = discount["amount"]
      projection_arguments[:discount_rate] = discount["rate"]
    end
    projection = ReceiptAmountService.count_item_extension_projection(**projection_arguments)
    original_line_total = projection.fetch(:original_line_total, projection[:projected_amount])
    if option.key?("discount")
      return unless exact_integer_matches?(attributes[:original_line_total], original_line_total)
      return unless exact_integer_matches?(attributes[:line_total], projection[:projected_amount])
    end
    return unless decision.projected_line_total == projection[:projected_amount]

    Selection.new(
      item_identity: decision.item_identity,
      item_index:,
      position_index: attributes[:position_index],
      proposal_id: decision.selected_proposal_id,
      pricing_source_kind: decision.selected_pricing_source_kind,
      price:,
      quantity: BigDecimal(quantity.to_s),
      quantity_unit_code: unit_code,
      original_line_total:,
      discount_amount: option.key?("discount") ? exact_integer(discount["amount"]) : nil,
      discount_rate: option.key?("discount") ? BigDecimal(discount["rate"]) : nil,
      projected_line_total: decision.projected_line_total,
      review_reason:
    )
  end

  def explicit_selection(decision, option, attributes, item_index:, review_reason:)
    source = option.fetch("source")
    line_total = exact_integer(source.fetch("line_total_amount"))
    return if line_total.nil?
    return unless exact_integer_matches?(attributes[:original_line_total], line_total)
    discount = normalized_hash(option["discount"])
    projected_line_total = line_total
    if option.key?("discount")
      return unless exact_integer_matches?(attributes[:discount_amount], exact_integer(discount["amount"]))
      return unless exact_decimal_matches?(attributes[:discount_rate], BigDecimal(discount["rate"]))

      projection = ReceiptAmountService.item_discount_projection(
        original_line_total: line_total,
        discount_amount: discount["amount"],
        discount_rate: discount["rate"]
      )
      projected_line_total = projection.fetch(:projected_amount)
    end
    return unless exact_integer_matches?(attributes[:line_total], projected_line_total)
    return unless decision.projected_line_total == projected_line_total

    Selection.new(
      item_identity: decision.item_identity,
      item_index:,
      position_index: attributes[:position_index],
      proposal_id: decision.selected_proposal_id,
      pricing_source_kind: decision.selected_pricing_source_kind,
      explicit_line_total: line_total,
      original_line_total: line_total,
      discount_amount: option.key?("discount") ? exact_integer(discount["amount"]) : nil,
      discount_rate: option.key?("discount") ? BigDecimal(discount["rate"]) : nil,
      projected_line_total: decision.projected_line_total,
      review_reason:
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
      elsif selection.pricing_source_kind == "reference_quantity_price"
        item[:price] = nil
        item[:quantity] = selection.quantity
        item[:quantity_unit_code] = selection.quantity_unit_code
        item[:quantity_unit_raw] = nil
        item[:reference_price_amount] = selection.reference_price_amount
        item[:reference_quantity] = selection.reference_quantity
        item[:reference_quantity_unit_code] = selection.reference_quantity_unit_code
        item[:reference_quantity_unit_raw] = nil
        item[:reference_price_tax_inclusion] = selection.reference_price_tax_inclusion
      else
        item[:price] = nil
      end
      if selection.reviewable?
        item[:needs_review] = true
        item[:review_reasons] = (Array(item[:review_reasons]).map(&:to_s) + [ selection.review_reason ]).uniq
      end
    end

    review_reasons = selections.filter_map(&:review_reason)
    candidate_params[:review_reasons] = (Array(candidate_params[:review_reasons]).map(&:to_s) + review_reasons).uniq
  end

  def clear_reference_source_fields!(item)
    REFERENCE_SOURCE_FIELDS.each { |field| item[field] = nil }
  end

  def final_result_valid?(candidate_params, final_amount_result, selections)
    return false unless final_amount_result.is_a?(Hash)

    candidate_items = Array(candidate_params[:receipt_items_attributes])
    return false unless candidate_items.size == Array(params[:receipt_items_attributes]).size
    return false unless financial_transition_valid?(candidate_params, final_amount_result, selections)
    return false unless unselected_computed_items_unchanged?(final_amount_result, selections)

    computed_items = Array(final_amount_result.dig(:computed, :items))
    selections.all? do |selection|
      item = normalized_hash(computed_items[selection.item_index])
      if uniform_net_count_selection?(selection, final_amount_result)
        next uniform_net_count_computed_item_valid?(item, selection)
      end
      original_line_total = selection.original_line_total || selection.projected_line_total
      next false unless exact_integer_matches?(item[:original_line_total], original_line_total)
      next false unless exact_integer_matches?(item[:line_total], selection.projected_line_total)

      case selection.pricing_source_kind
      when "count_unit_price"
        exact_integer_matches?(item[:price], selection.price) &&
          exact_integer_matches?(item[:quantity], selection.quantity.to_i) &&
          item[:quantity_unit_code] == selection.quantity_unit_code &&
          computed_discount_valid?(item, selection)
      when "reference_quantity_price"
        reference_computed_item_valid?(item, selection)
      else
        item[:price].nil? && computed_discount_valid?(item, selection)
      end
    end
  end

  def uniform_net_count_selection?(selection, final_amount_result)
    selection.pricing_source_kind == "count_unit_price" &&
      selection.discount_amount.nil? && selection.discount_rate.nil? &&
      count_tax_semantics == "reproducible_uniform_net" &&
      uniform_net_profile?(final_amount_result)
  end

  def uniform_net_count_computed_item_valid?(item, selection)
    preliminary_item = Array(preliminary_amount_result.dig(:computed, :items))[selection.item_index]

    computed_item_signature(item) == computed_item_signature(preliminary_item) &&
      exact_integer_matches?(item[:original_line_total], selection.projected_line_total) &&
      exact_integer_matches?(item[:quantity], selection.quantity.to_i) &&
      item[:quantity_unit_code] == selection.quantity_unit_code &&
      item[:discount_amount].nil? && item[:discount_rate].nil?
  end

  def computed_discount_valid?(item, selection)
    return true if selection.discount_amount.nil? && selection.discount_rate.nil?

    exact_integer_matches?(item[:discount_amount], selection.discount_amount) &&
      exact_decimal_matches?(item[:discount_rate], selection.discount_rate)
  end

  def reference_computed_item_valid?(item, selection)
    preliminary_item = normalized_hash(
      Array(preliminary_amount_result.dig(:computed, :items))[selection.item_index]
    )
    final_context = item.slice(*NO_TOTAL_STABLE_SELECTED_ITEM_FIELDS)
    preliminary_context = preliminary_item.slice(*NO_TOTAL_STABLE_SELECTED_ITEM_FIELDS)

    item[:price].nil? &&
      exact_decimal_matches?(item[:quantity], selection.quantity) &&
      item[:quantity_unit_code] == selection.quantity_unit_code &&
      final_context == preliminary_context
  end

  def financial_transition_valid?(candidate_params, final_amount_result, selections)
    return true if financial_result_signature(final_amount_result) ==
      financial_result_signature(preliminary_amount_result)
    return true if resolved_item_total_transition_valid?(final_amount_result)

    no_total_reference_transition_valid?(candidate_params, final_amount_result, selections)
  end

  def resolved_item_total_transition_valid?(final_amount_result)
    return false unless financial_value_signature(final_amount_result) ==
      financial_value_signature(preliminary_amount_result)
    return false unless final_amount_result[:selected_candidate_status].to_s == "accepted"
    return false unless normalized_hash(final_amount_result[:amount_engine])[:no_safe_candidate] == false

    review_transition_valid?(
      final_amount_result,
      allowed_removed_values: RESOLVED_ITEM_TOTAL_ALLOWED_REMOVED_REVIEW_VALUES,
      allow_remaining_review: true
    )
  end

  def no_total_reference_transition_valid?(candidate_params, final_amount_result, selections)
    no_total_selections = selections.select do |selection|
      selection.pricing_source_kind == "reference_quantity_price" && selection.printed_line_total.nil?
    end
    return false unless no_total_selections.one?

    selection = no_total_selections.sole
    return false unless no_total_candidate_params_valid?(candidate_params, selection)
    return false unless no_total_result_context_unchanged?(final_amount_result)
    return false unless no_total_amount_result_safe?(final_amount_result)
    return false unless review_transition_valid?(
      final_amount_result,
      allowed_removed_values: NO_TOTAL_ALLOWED_REMOVED_REVIEW_VALUES
    )
    return false unless non_no_total_computed_items_unchanged?(final_amount_result, selection)
    return false unless no_total_aggregate_valid?(final_amount_result)

    true
  end

  def no_total_candidate_params_valid?(candidate_params, selection)
    return false unless non_item_params_unchanged?(candidate_params)

    source_item = normalized_hash(Array(params[:receipt_items_attributes])[selection.item_index])
    candidate_item = normalized_hash(Array(candidate_params[:receipt_items_attributes])[selection.item_index])
    preliminary_item = normalized_hash(Array(preliminary_amount_result.dig(:computed, :items))[selection.item_index])

    source_item[:original_line_total].nil? &&
      source_item[:line_total].nil? &&
      candidate_item[:original_line_total].nil? &&
      candidate_item[:line_total].nil? &&
      preliminary_item[:amount_line_total_present] == false &&
      other_items_have_amount_source?(selection.item_index)
  end

  def other_items_have_amount_source?(selected_index)
    Array(preliminary_amount_result.dig(:computed, :items)).each_with_index.all? do |item, index|
      index == selected_index || normalized_hash(item)[:amount_line_total_present] == true
    end
  end

  def non_item_params_unchanged?(candidate_params)
    %i[
      receipt_attributes
      receipt_tax_details_attributes
      receipt_adjustments_attributes
      receipt_payments_attributes
    ].all? { |key| candidate_params[key] == params[key] }
  end

  def no_total_result_context_unchanged?(final_amount_result)
    preliminary_computed = normalized_hash(preliminary_amount_result[:computed])
    final_computed = normalized_hash(final_amount_result[:computed])
    preliminary_engine = normalized_hash(preliminary_amount_result[:amount_engine])
    final_engine = normalized_hash(final_amount_result[:amount_engine])

    normalized_hash(final_amount_result[:calculation_profile]) ==
      normalized_hash(preliminary_amount_result[:calculation_profile]) &&
      final_amount_result[:tax_details] == preliminary_amount_result[:tax_details] &&
      final_computed.slice(*NO_TOTAL_STABLE_COMPUTED_RECEIPT_FIELDS) ==
        preliminary_computed.slice(*NO_TOTAL_STABLE_COMPUTED_RECEIPT_FIELDS) &&
      final_engine.slice(:selected_candidate_id, :selected_basis) ==
        preliminary_engine.slice(:selected_candidate_id, :selected_basis)
  end

  def no_total_amount_result_safe?(final_amount_result)
    final_amount_result[:selected_candidate_status].to_s == "accepted" &&
      normalized_hash(final_amount_result[:amount_engine])[:no_safe_candidate] == false &&
      final_amount_result[:safe_to_auto_complete] == true &&
      final_amount_result[:needs_review] == false
  end

  def review_transition_valid?(final_amount_result, allowed_removed_values:, allow_remaining_review: false)
    AMOUNT_REVIEW_FIELDS.all? do |field|
      case field
      when :needs_review
        final_amount_result[field] == false ||
          (allow_remaining_review && final_amount_result[field] == true && preliminary_amount_result[field] == true)
      else
        preliminary_values = Array(preliminary_amount_result[field]).map(&:to_s)
        final_values = Array(final_amount_result[field]).map(&:to_s)
        removed = preliminary_values - final_values
        added = final_values - preliminary_values

        allowed_removed = allowed_removed_values.fetch(field, [])
        added.empty? && (removed - allowed_removed).empty?
      end
    end
  end

  def non_no_total_computed_items_unchanged?(final_amount_result, no_total_selection)
    preliminary_items = Array(preliminary_amount_result.dig(:computed, :items))
    final_items = Array(final_amount_result.dig(:computed, :items))
    return false unless preliminary_items.size == final_items.size

    preliminary_items.each_index.all? do |index|
      index == no_total_selection.item_index ||
        computed_item_signature(preliminary_items[index]) == computed_item_signature(final_items[index])
    end
  end

  def no_total_aggregate_valid?(final_amount_result)
    resolved = normalized_hash(final_amount_result[:resolved])
    computed = normalized_hash(final_amount_result[:computed])
    source_receipt = normalized_hash(params[:receipt_attributes])
    resolved_amounts = resolved.slice(:subtotal, :tax, :total, :tax_rate)
    computed_amounts = computed.slice(:subtotal, :tax, :total, :tax_rate)
    return false unless resolved_amounts == computed_amounts
    return false unless exact_integer_matches?(computed[:purchase_total], resolved[:total])
    return false unless exact_integer_matches?(computed[:final_payment_total], resolved[:total])
    return false unless receipt_amount_matches?(source_receipt[:subtotal_amount], resolved[:subtotal])
    return false unless receipt_amount_matches?(source_receipt[:tax_amount], resolved[:tax])
    return false unless receipt_amount_matches?(source_receipt[:total_amount], resolved[:total])

    true
  end

  def receipt_amount_matches?(source, resolved)
    source.nil? || exact_integer_matches?(source, resolved)
  end

  def unselected_computed_items_unchanged?(final_amount_result, selections)
    preliminary_items = Array(preliminary_amount_result.dig(:computed, :items))
    final_items = Array(final_amount_result.dig(:computed, :items))
    return false unless preliminary_items.size == final_items.size

    selected_indexes = selections.to_h { |selection| [ selection.item_index, true ] }
    preliminary_items.each_index.all? do |index|
      selected_indexes[index] ||
        computed_item_signature(preliminary_items[index]) == computed_item_signature(final_items[index])
    end
  end

  def computed_item_signature(item)
    normalized_hash(item).slice(*COMPUTED_ITEM_INVARIANT_FIELDS)
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

  def financial_value_signature(result)
    financial_result_signature(result).except(:review)
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

  def exact_decimal(value, maximum:, maximum_scale:, allow_zero:)
    return unless value.is_a?(String)
    return unless value.bytesize <= PROPOSAL_CONTRACT::MAX_EXACT_NUMBER_BYTES
    return unless value.match?(PROPOSAL_CONTRACT::EXACT_DECIMAL_PATTERN)

    decimal = BigDecimal(value)
    return if decimal.negative? || (!allow_zero && decimal.zero?) || decimal > maximum

    scale = value.include?(".") ? value.length - value.index(".") - 1 : 0
    decimal if scale <= maximum_scale
  rescue ArgumentError
    nil
  end

  def exact_decimal_matches?(value, expected)
    decimal = BigDecimal(value.to_s)
    decimal.finite? && decimal == expected
  rescue ArgumentError, TypeError
    false
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

  def canonical_unit(value)
    unit = ReceiptQuantityUnit.unit_for(value)
    value if value.is_a?(String) && unit&.code == value
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
