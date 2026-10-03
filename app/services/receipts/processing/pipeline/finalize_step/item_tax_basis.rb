class Receipts::Processing::Pipeline::FinalizeStep::ItemTaxBasis
  ITEM_FIELDS = %i[
    price
    quantity
    quantity_unit_code
    original_line_total
    line_total
    discount_amount
    discount_rate
    tax_rate
  ].freeze
  SOURCE_FIELDS = %i[
    quantity
    quantity_unit_code
    original_line_total
    discount_amount
    discount_rate
  ].freeze

  def self.call(amount_result:, items:)
    new(amount_result:, items:).call
  end

  def initialize(amount_result:, items:)
    @amount_result = amount_result
    @items = items
  end

  def call
    return unless amount_result.is_a?(Hash) && items.is_a?(Array)
    return unless items.size.between?(1, Receipts::Processing::Contracts::ItemCalculationModeProposalSet::MAX_SETS)

    engine = normalized_hash(amount_result[:amount_engine])
    selected = normalized_hash(engine[:selected_candidate])
    computed = normalized_hash(amount_result[:computed])
    return unless accepted_result?(engine, selected, computed)

    calculated_items = computed[:items]
    selected_items = selected[:computed_items]
    evidence = selected[:evidence]
    return unless calculated_items.is_a?(Array) && calculated_items.size == items.size
    return unless selected_items.is_a?(Array) && selected_items.size == items.size
    if selected[:basis] == "items_as_tax_excluded"
      return uniform_net_bases(calculated_items, selected_items)
    end
    return unless evidence.is_a?(Array)

    entries = evidence.filter_map do |entry|
      return unless entry.is_a?(Hash)

      value = normalized_hash(entry)
      value if value[:source].to_s == "receipt_items"
    end
    return unless entries.all? { |entry| entry[:index].is_a?(Integer) && entry[:index].between?(0, items.size - 1) }
    return unless entries.map { |entry| entry[:index] }.uniq.size == entries.size

    entries_by_index = entries.index_by { |entry| entry[:index] }
    bases = items.map.with_index do |source, index|
      item = normalized_hash(source)
      calculated = normalized_hash(calculated_items[index])
      snapshot = normalized_hash(selected_items[index])
      return unless source_matches?(item, calculated, snapshot)

      basis = basis_for(item, calculated, entries_by_index[index])
      return unless basis

      basis
    end
    bases.freeze
  rescue ArgumentError, EncodingError, TypeError
    nil
  end

  private

  attr_reader :amount_result, :items

  def accepted_result?(engine, selected, computed)
    resolved = normalized_hash(amount_result[:resolved])
    amount_result[:selected_candidate_status] == "accepted" &&
      engine[:selected_candidate_status] == "accepted" &&
      engine[:no_safe_candidate] == false &&
      selected[:candidate_id].is_a?(String) &&
      selected[:candidate_id].present? &&
      engine[:selected_candidate_id] == selected[:candidate_id] &&
      computed[:amount_engine_candidate_id] == selected[:candidate_id] &&
      %w[mixed_by_tax_rate_group items_as_tax_excluded].include?(selected[:basis]) &&
      engine[:selected_basis] == selected[:basis] &&
      computed[:amount_engine_basis] == selected[:basis] &&
      selected[:hard_reject_reasons] == [] &&
      resolved[:subtotal] == selected[:subtotal] &&
      resolved[:tax] == selected[:tax] &&
      resolved[:total] == selected[:purchase_total]
  end

  def uniform_net_bases(calculated_items, selected_items)
    bases = items.map.with_index do |source, index|
      item = normalized_hash(source)
      calculated = normalized_hash(calculated_items[index])
      return unless source_matches?(item, calculated, normalized_hash(selected_items[index]))
      return if item[:pricing_source_kind] == "reference_quantity_price"
      if calculated[:pricing_source_kind] == "explicit_line_total"
        return unless calculated[:input_tax_inclusion] == "net" && calculated[:tax_inclusion_origin] == "analysis"
      end
      rate = calculated[:tax_rate]
      return unless rate.is_a?(Numeric) && rate.finite? && rate.between?(0, 1)
      return unless bounded_amount?(calculated[:line_total]) && calculated[:line_total] >= item[:line_total]

      rate.zero? ? basis_for(item, calculated, nil) : "net"
    end
    bases.freeze if bases.all?
  end

  def source_matches?(item, calculated, snapshot)
    ITEM_FIELDS.all? { |field| calculated[field] == snapshot[field] } &&
      SOURCE_FIELDS.all? { |field| item[field] == calculated[field] } &&
      valid_source_amount?(item)
  end

  def valid_source_amount?(item)
    original = item[:original_line_total]
    total = item[:line_total]
    discount = item[:discount_amount] || 0

    [ original, total, discount ].all? { |value| bounded_amount?(value) } &&
      discount <= original &&
      original - discount == total
  end

  def basis_for(item, calculated, evidence)
    rate = calculated[:tax_rate]
    return unless rate.is_a?(Numeric) && rate.finite? && rate.between?(0, 1)
    if rate.zero?
      return unless evidence.nil? && (item[:tax_rate].nil? || item[:tax_rate] == rate)
      return unless item[:line_total] == calculated[:line_total]

      return "gross"
    end
    return unless evidence && evidence[:rate] == rate

    net = evidence[:net_amount]
    tax = evidence[:tax_amount]
    gross = evidence[:gross_amount]
    return unless [ net, tax, gross ].all? { |value| bounded_amount?(value) }
    return unless net + tax == gross && calculated[:line_total] == gross

    case evidence[:basis].to_s
    when "tax_excluded"
      "net" if item[:line_total] == net
    when "tax_included"
      "gross" if item[:line_total] == gross
    end
  end

  def bounded_amount?(value)
    value.is_a?(Integer) && value.between?(0, ReceiptItem::GROSS_LINE_TOTAL_MAX)
  end

  def normalized_hash(value)
    value.is_a?(Hash) ? value.symbolize_keys : {}
  end
end
