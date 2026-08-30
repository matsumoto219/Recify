class Receipts::Processing::Pipeline::FinalizeStep::AttributeNormalizer
  ITEM_PRICING_MODE_REVIEW_REASON = "item_pricing_mode_uncertain"
  LAYOUT_ITEM_IDENTITY_PATTERN = /
    \Aazure_item_layout_item_p(?<page_index>0)
    _name_l(?<name_line_index>0|[1-9]\d*)
    _s(?<provider_span_start>0|[1-9]\d*)
    _e(?<provider_span_end>0|[1-9]\d*)
    _ref_l(?<reference_line_index>0|[1-9]\d*)
    _qty_l(?<quantity_line_index>0|[1-9]\d*)
    _total_l(?<total_line_index>0|[1-9]\d*)\z
  /x.freeze
  LAYOUT_PROPOSAL_ID_PATTERN = /
    \Aazure_item_layout_p(?<page_index>0)
    _name_l(?<name_line_index>0|[1-9]\d*)
    _ref_l(?<reference_line_index>0|[1-9]\d*)
    _qty_l(?<quantity_line_index>0|[1-9]\d*)
    _total_l(?<total_line_index>0|[1-9]\d*)
    _explicit_line_total\z
  /x.freeze
  STRUCTURED_ITEM_IDENTITY_PATTERN = /
    \Aazure_structured_item_i(?<item_index>0|[1-9]\d*)
    _s(?<provider_span_start>0|[1-9]\d*)
    _e(?<provider_span_end>0|[1-9]\d*)\z
  /x.freeze
  STRUCTURED_ITEM_PROPOSAL_ID_PATTERN = /
    \Aazure_items_(?<item_index>0|[1-9]\d*)
    _(?<pricing_source_kind>count_unit_price|reference_quantity_price|explicit_line_total)\z
  /x.freeze
  STRUCTURED_LAYOUT_REFERENCE_PROPOSAL_ID_PATTERN = /
    \Aazure_item_layout_p(?<page_index>0)
    _name_l(?<name_line_index>0|[1-9]\d*)
    _ref_l(?<reference_line_index>0|[1-9]\d*)
    _qty_l(?<quantity_line_index>0|[1-9]\d*)
    _total_l(?<total_line_index>0|[1-9]\d*)
    _reference_quantity_price\z
  /x.freeze

  class << self
    def items(
      value,
      trusted_reference_pricing_auto_adoption: false,
      trusted_item_calculation_mode_sources: [],
      item_price_limit: nil,
      item_line_total_limit: nil
    )
      trusted_sources = trusted_item_calculation_mode_source_map(
        value,
        trusted_item_calculation_mode_sources,
        item_price_limit:,
        item_line_total_limit:
      )
      trusted_sources = {} if trusted_reference_pricing_auto_adoption

      Array(value).filter_map.with_index do |item, index|
        symbolized = normalized_attributes(item)
        price = amount(symbolized[:price])
        original_line_total = amount(symbolized[:original_line_total])
        line_total = amount(symbolized[:line_total])
        discount_amount = amount(symbolized[:discount_amount])
        next if [ price, original_line_total, line_total, discount_amount ].compact.any?(&:negative?)
        quantity_unit_code = ReceiptQuantityUnit.normalize(symbolized[:quantity_unit_code])

        attributes = {
          raw_text: symbolized[:raw_text].to_s,
          suggested_name: symbolized[:suggested_name].presence,
          confirmed_name: symbolized[:confirmed_name].presence,
          category: symbolized[:category].presence,
          price: price,
          quantity: quantity(symbolized[:quantity]),
          quantity_unit_code: quantity_unit_code,
          product_code: symbolized[:product_code].presence,
          tax_rate: tax_rate(symbolized[:tax_rate]),
          original_line_total: original_line_total,
          line_total: line_total,
          discount_amount: discount_amount,
          discount_rate: tax_rate(symbolized[:discount_rate]),
          # item-level needs_review は前段で決めた値を保持し、この層では再判定しない。
          needs_review: symbolized[:needs_review],
          review_reasons: review_reasons(symbolized[:review_reasons]),
          position_index: symbolized[:position_index] || index + 1,
          confidence: confidence(symbolized[:confidence])
        }
        if trusted_reference_pricing_auto_adoption
          reference_source = trusted_reference_source_attributes(symbolized)
          next if reference_source.nil?

          attributes.merge!(reference_source)
        elsif (selection = trusted_sources[symbolized[:ocr_item_identity]])
          attributes.merge!(trusted_item_calculation_mode_source_attributes(selection))
        end
        attributes
      end
    end

    def adjustments(value)
      Array(value).filter_map.with_index do |adjustment, index|
        symbolized = normalized_attributes(adjustment)
        normalized_amount = amount(symbolized[:amount])
        next unless normalized_amount&.positive?

        kind = symbolized[:kind].to_s
        sign = symbolized[:sign].to_s
        source = symbolized[:source].to_s.presence || "ai"

        {
          kind: ReceiptAdjustment::KINDS.include?(kind) ? kind : "other",
          label: symbolized[:label].to_s.strip.presence,
          amount: normalized_amount.abs,
          sign: ReceiptAdjustment::SIGNS.include?(sign) ? sign : "discount",
          tax_rate: tax_rate(symbolized[:tax_rate]),
          source: ReceiptAdjustment::SOURCES.include?(source) ? source : "ai",
          source_text: symbolized[:source_text].to_s.strip.presence,
          source_line_index: symbolized[:source_line_index],
          confidence: confidence(symbolized[:confidence]),
          needs_review: symbolized[:needs_review] == true,
          review_reasons: review_reasons(symbolized[:review_reasons]),
          position_index: symbolized[:position_index] || index + 1
        }.compact
      end
    end

    def review_reasons(value)
      Array(value).filter_map do |reason|
        normalized = reason.to_s.strip
        normalized.presence
      end.uniq
    end

    def amount(value)
      ReceiptAmountService.parse_amount_or_nil(value)
    end

    def safe_calculated_amount(value)
      normalized_amount = amount(value)
      normalized_amount&.negative? ? nil : normalized_amount
    end

    def quantity(value)
      normalized_quantity = ReceiptAmountService.parse_quantity(value, default: BigDecimal("1"))

      normalized_quantity.positive? ? normalized_quantity : BigDecimal("1")
    end

    def tax_rate(value)
      return nil if value.blank?

      normalized_tax_rate = BigDecimal(value.to_s.delete("%"))
      normalized_tax_rate > 1 ? normalized_tax_rate / 100 : normalized_tax_rate
    rescue ArgumentError
      nil
    end

    def confidence(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    private

    def trusted_item_calculation_mode_source_map(
      items,
      selections,
      item_price_limit:,
      item_line_total_limit:
    )
      selections = Array(selections)
      return {} if selections.empty?
      return {} unless selections.size <= Receipts::Processing::Contracts::ItemCalculationModeProposalSet::MAX_SETS
      return {} unless valid_item_calculation_mode_limit?(item_price_limit)
      return {} unless valid_item_calculation_mode_limit?(item_line_total_limit)

      selection_class = Receipts::Processing::Pipeline::FinalizeStep::ItemCalculationModeApplicator::Selection
      return {} unless selections.all? { |selection| selection.is_a?(selection_class) }

      identities = selections.map(&:item_identity)
      return {} unless identities.uniq.size == identities.size

      normalized_items = Array(items).map { |item| normalized_attributes(item) }
      items_by_identity = normalized_items.each_with_index.each_with_object({}) do |(item, index), result|
        identity = item[:ocr_item_identity]
        next if identity.blank?

        (result[identity] ||= []) << [ item, index ]
      end
      selection_map = selections.each_with_object({}) do |selection, result|
        matches = items_by_identity[selection.item_identity]
        return {} unless matches&.one?

        item, index = matches.sole
        return {} unless index == selection.item_index
        return {} unless item[:position_index] == selection.position_index
        return {} unless trusted_item_calculation_mode_source_valid?(
          item,
          selection,
          item_price_limit:,
          item_line_total_limit:
        )

        result[selection.item_identity] = selection
      end

      selection_map.freeze
    end

    def trusted_item_calculation_mode_source_valid?(
      item,
      selection,
      item_price_limit:,
      item_line_total_limit:
    )
      return false unless valid_item_calculation_mode_identity?(selection.item_identity)
      return false unless valid_item_calculation_mode_proposal_id?(selection)
      return false unless selection.projected_line_total.is_a?(Integer)
      return false unless selection.projected_line_total.between?(0, item_line_total_limit)
      return false unless trusted_item_calculation_mode_review_valid?(item, selection)
      return false unless item[:pricing_source_kind] == selection.pricing_source_kind
      unless selection.pricing_source_kind == "count_unit_price"
        return false unless item[:discount_amount].nil? && item[:discount_rate].nil?
      end

      case selection.pricing_source_kind
      when "count_unit_price"
        return false unless reference_source_absent?(item)

        trusted_count_source_valid?(item, selection, item_price_limit:, item_line_total_limit:)
      when "reference_quantity_price"
        trusted_reference_item_calculation_source_valid?(item, selection)
      when "explicit_line_total"
        return false unless reference_source_absent?(item)

        trusted_explicit_source_valid?(item, selection)
      else
        false
      end
    end

    def trusted_item_calculation_mode_review_valid?(item, selection)
      return false unless selection.review_reason.nil? ||
        selection.review_reason == ITEM_PRICING_MODE_REVIEW_REASON

      review_reasons = self.review_reasons(item[:review_reasons])
      if selection.review_reason
        item[:needs_review] == true && review_reasons.include?(selection.review_reason)
      else
        review_reasons.exclude?(ITEM_PRICING_MODE_REVIEW_REASON)
      end
    end

    def trusted_count_source_valid?(item, selection, item_price_limit:, item_line_total_limit:)
      unit = ReceiptQuantityUnit.unit_for(selection.quantity_unit_code)

      selection.price.is_a?(Integer) &&
        selection.price.between?(0, item_price_limit) &&
        exact_count_quantity?(selection.quantity) &&
        unit&.kind == :countable &&
        unit.code == selection.quantity_unit_code &&
        item[:price].is_a?(Integer) && item[:price] == selection.price &&
        item[:quantity].is_a?(BigDecimal) && item[:quantity] == selection.quantity &&
        item[:quantity_unit_code] == selection.quantity_unit_code &&
        item[:quantity_unit_raw].nil? &&
        trusted_count_totals_valid?(item, selection, item_line_total_limit:)
    end

    def trusted_count_totals_valid?(item, selection, item_line_total_limit:)
      if selection.discount_amount.nil? && selection.discount_rate.nil?
        return item[:discount_amount].nil? && item[:discount_rate].nil? &&
          exact_item_total_matches?(item, selection.projected_line_total)
      end
      return false unless selection.original_line_total.is_a?(Integer)
      return false unless selection.original_line_total.between?(0, item_line_total_limit)
      return false unless item[:original_line_total].is_a?(Integer) && item[:line_total].is_a?(Integer)
      return false unless item[:discount_amount].is_a?(Integer) && item[:discount_rate].is_a?(BigDecimal)
      return false unless item[:discount_amount] == selection.discount_amount && item[:discount_rate] == selection.discount_rate

      projection = ReceiptAmountService.count_item_extension_projection(
        price_amount: selection.price,
        purchased_quantity: selection.quantity,
        purchased_unit_code: selection.quantity_unit_code,
        discount_amount: selection.discount_amount,
        discount_rate: selection.discount_rate
      )
      item[:original_line_total] == projection[:original_line_total] &&
        selection.original_line_total == projection[:original_line_total] &&
        item[:line_total] == projection[:projected_amount] &&
        selection.projected_line_total == projection[:projected_amount]
    rescue ReceiptAmountService::InvalidItemSourceError
      false
    end

    def trusted_explicit_source_valid?(item, selection)
      selection.explicit_line_total.is_a?(Integer) &&
        selection.explicit_line_total == selection.projected_line_total &&
        item[:price].nil? &&
        exact_item_total_matches?(item, selection.explicit_line_total)
    end

    def trusted_reference_item_calculation_source_valid?(item, selection)
      reference_unit = ReceiptQuantityUnit.unit_for(selection.reference_quantity_unit_code)
      purchased_unit = ReceiptQuantityUnit.unit_for(selection.quantity_unit_code)
      return false unless reference_unit&.code == selection.reference_quantity_unit_code
      return false unless purchased_unit&.code == selection.quantity_unit_code
      return false unless reference_unit.allows_pricing_role?(:reference)
      return false unless purchased_unit.allows_pricing_role?(:purchased)
      return false unless ReceiptQuantityUnit.convertible?(from: purchased_unit.code, to: reference_unit.code)

      selection.reference_price_amount.is_a?(BigDecimal) &&
        selection.reference_price_amount.finite? &&
        selection.reference_price_amount.between?(0, ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX) &&
        selection.reference_quantity.is_a?(BigDecimal) &&
        selection.reference_quantity.finite? &&
        selection.reference_quantity.positive? &&
        selection.reference_quantity <= ReceiptItem::REFERENCE_QUANTITY_MAX &&
        selection.quantity.is_a?(BigDecimal) &&
        selection.quantity.finite? &&
        selection.quantity.positive? &&
        selection.quantity <= ReceiptItem::REFERENCE_QUANTITY_MAX &&
        selection.price.nil? &&
        selection.explicit_line_total.nil? &&
        selection.reference_price_tax_inclusion == "gross" &&
        item[:price].nil? &&
        item[:quantity] == selection.quantity &&
        item[:quantity_unit_code] == purchased_unit.code &&
        item[:quantity_unit_raw].nil? &&
        item[:reference_price_amount] == selection.reference_price_amount &&
        item[:reference_quantity] == selection.reference_quantity &&
        item[:reference_quantity_unit_code] == reference_unit.code &&
        item[:reference_quantity_unit_raw].nil? &&
        item[:reference_price_tax_inclusion] == "gross" &&
        exact_item_total_matches?(item, selection.projected_line_total)
    rescue ReceiptQuantityUnit::ConversionError
      false
    end

    def exact_count_quantity?(value)
      value.is_a?(BigDecimal) &&
        value.finite? &&
        value.frac.zero? &&
        value.between?(1, Receipts::Processing::Contracts::ItemCalculationModeProposalSet::MAX_QUANTITY)
    end

    def exact_item_total_matches?(item, expected)
      item[:original_line_total].is_a?(Integer) &&
        item[:line_total].is_a?(Integer) &&
        item[:original_line_total] == expected &&
        item[:line_total] == expected
    end

    def reference_source_absent?(item)
      %i[
        reference_price_amount
        reference_quantity
        reference_quantity_unit_code
        reference_quantity_unit_raw
        reference_price_tax_inclusion
      ].all? { |field| item[field].nil? }
    end

    def valid_item_calculation_mode_identity?(value)
      return false unless value.is_a?(String)
      return false if value.bytesize > Receipts::Processing::Contracts::ItemCalculationModeProposalSet::MAX_ID_BYTES
      return true if value.match?(STRUCTURED_ITEM_IDENTITY_PATTERN)

      layout_item_identity_valid?(value)
    end

    def valid_item_calculation_mode_proposal_id?(selection)
      value = selection.proposal_id
      return false unless value.is_a?(String)
      return false if value.bytesize > Receipts::Processing::Contracts::ItemCalculationModeProposalSet::MAX_ID_BYTES
      structured_identity = STRUCTURED_ITEM_IDENTITY_PATTERN.match(selection.item_identity)
      if structured_identity
        return structured_item_proposal_link_valid?(selection, structured_identity:)
      end

      layout_item_proposal_link_valid?(selection)
    end

    def structured_item_proposal_link_valid?(selection, structured_identity:)
      proposal = STRUCTURED_ITEM_PROPOSAL_ID_PATTERN.match(selection.proposal_id)
      if proposal
        return proposal[:item_index] == structured_identity[:item_index] &&
          proposal[:pricing_source_kind] == selection.pricing_source_kind
      end
      return false unless selection.pricing_source_kind == "reference_quantity_price"

      layout_proposal = STRUCTURED_LAYOUT_REFERENCE_PROPOSAL_ID_PATTERN.match(selection.proposal_id)
      return false if layout_proposal.nil?

      %i[
        name_line_index
        reference_line_index
        quantity_line_index
        total_line_index
      ].all? do |key|
        layout_proposal[key].to_i.between?(
          0,
          Receipts::Processing::Contracts::ItemCalculationModeProposalSet::MAX_LAYOUT_LINE_INDEX
        )
      end
    end

    def layout_item_identity_valid?(value)
      identity = LAYOUT_ITEM_IDENTITY_PATTERN.match(value)
      return false if identity.nil?

      span_start = identity[:provider_span_start].to_i
      span_end = identity[:provider_span_end].to_i
      line_indexes = %i[
        name_line_index
        reference_line_index
        quantity_line_index
        total_line_index
      ].map { |key| identity[key].to_i }

      line_indexes.all? do |index|
        index.between?(0, Receipts::Processing::Contracts::ItemCalculationModeProposalSet::MAX_LAYOUT_LINE_INDEX)
      end &&
        span_start.between?(0, Receipts::Processing::Contracts::ItemCalculationModeProposalSet::MAX_PROVIDER_SPAN) &&
        span_end.between?(1, Receipts::Processing::Contracts::ItemCalculationModeProposalSet::MAX_PROVIDER_SPAN) &&
        span_end > span_start
    end

    def layout_item_proposal_link_valid?(selection)
      return false unless selection.pricing_source_kind == "explicit_line_total"

      identity = LAYOUT_ITEM_IDENTITY_PATTERN.match(selection.item_identity)
      proposal = LAYOUT_PROPOSAL_ID_PATTERN.match(selection.proposal_id)
      return false if identity.nil? || proposal.nil?
      return false unless layout_item_identity_valid?(selection.item_identity)
      return false unless %i[
        name_line_index
        reference_line_index
        quantity_line_index
        total_line_index
      ].all? do |key|
        proposal[key].to_i.between?(
          0,
          Receipts::Processing::Contracts::ItemCalculationModeProposalSet::MAX_LAYOUT_LINE_INDEX
        )
      end

      %i[
        page_index
        name_line_index
        reference_line_index
        quantity_line_index
        total_line_index
      ].all? { |key| identity[key] == proposal[key] }
    end

    def valid_item_calculation_mode_limit?(value)
      value.is_a?(Integer) &&
        value.between?(0, Receipts::Processing::Contracts::ItemCalculationModeProposalSet::MAX_AMOUNT)
    end

    def trusted_item_calculation_mode_source_attributes(selection)
      attributes = {
        price: selection.price,
        pricing_source_kind: selection.pricing_source_kind,
        reference_price_amount: nil,
        reference_quantity: nil,
        reference_quantity_unit_code: nil,
        reference_quantity_unit_raw: nil,
        reference_price_tax_inclusion: nil
      }
      case selection.pricing_source_kind
      when "count_unit_price"
        attributes.merge!(
          quantity: selection.quantity,
          quantity_unit_code: selection.quantity_unit_code,
          quantity_unit_raw: nil
        )
      when "reference_quantity_price"
        attributes.merge!(
          quantity: selection.quantity,
          quantity_unit_code: selection.quantity_unit_code,
          quantity_unit_raw: nil,
          reference_price_amount: selection.reference_price_amount,
          reference_quantity: selection.reference_quantity,
          reference_quantity_unit_code: selection.reference_quantity_unit_code,
          reference_quantity_unit_raw: nil,
          reference_price_tax_inclusion: selection.reference_price_tax_inclusion
        )
      else
        attributes.merge!(
          original_line_total: selection.explicit_line_total,
          line_total: selection.projected_line_total
        )
      end
      attributes
    end

    def trusted_reference_source_attributes(attributes)
      return unless attributes[:pricing_source_kind] == "reference_quantity_price"
      return unless attributes[:reference_price_tax_inclusion] == "gross"
      return unless attributes[:quantity_unit_raw].nil? && attributes[:reference_quantity_unit_raw].nil?

      reference_price = exact_decimal(
        attributes[:reference_price_amount],
        maximum: ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX,
        maximum_scale: ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX_SCALE,
        allow_zero: true
      )
      reference_quantity = exact_decimal(
        attributes[:reference_quantity],
        maximum: ReceiptItem::REFERENCE_QUANTITY_MAX,
        maximum_scale: ReceiptItem::REFERENCE_QUANTITY_MAX_SCALE,
        allow_zero: false
      )
      purchased_quantity = exact_decimal(
        attributes[:quantity],
        maximum: ReceiptItem::REFERENCE_QUANTITY_MAX,
        maximum_scale: ReceiptItem::REFERENCE_QUANTITY_MAX_SCALE,
        allow_zero: false
      )
      purchased_unit = canonical_unit(attributes[:quantity_unit_code])
      reference_unit = canonical_unit(attributes[:reference_quantity_unit_code])
      return if [ reference_price, reference_quantity, purchased_quantity, purchased_unit, reference_unit ].any?(&:nil?)
      return unless ReceiptQuantityUnit.convertible?(from: purchased_unit, to: reference_unit)

      {
        price: nil,
        quantity: purchased_quantity,
        quantity_unit_code: purchased_unit,
        quantity_unit_raw: nil,
        pricing_source_kind: "reference_quantity_price",
        reference_price_amount: reference_price,
        reference_quantity: reference_quantity,
        reference_quantity_unit_code: reference_unit,
        reference_quantity_unit_raw: nil,
        reference_price_tax_inclusion: "gross"
      }
    rescue ReceiptQuantityUnit::ConversionError
      nil
    end

    def exact_decimal(value, maximum:, maximum_scale:, allow_zero:)
      source = case value
      when String
        return unless value.match?(/\A(?:0|[1-9]\d*)(?:\.\d*[1-9])?\z/)

        value
      when Integer
        value.to_s
      when BigDecimal
        return unless value.finite?

        value.to_s("F").sub(/\.0+\z/, "").sub(/(\.\d*?)0+\z/, "\\1")
      else
        return
      end

      decimal = BigDecimal(source)
      return if decimal.negative? || (!allow_zero && decimal.zero?) || decimal > maximum

      scale = source.include?(".") ? source.length - source.index(".") - 1 : 0
      decimal if scale <= maximum_scale
    rescue ArgumentError, TypeError
      nil
    end

    def canonical_unit(value)
      unit = ReceiptQuantityUnit.unit_for(value)
      value if value.is_a?(String) && unit&.code == value
    end

    def normalized_attributes(value)
      if value.respond_to?(:with_indifferent_access)
        value.with_indifferent_access
      elsif value.respond_to?(:symbolize_keys)
        value.symbolize_keys.with_indifferent_access
      else
        {}.with_indifferent_access
      end
    end
  end
end
