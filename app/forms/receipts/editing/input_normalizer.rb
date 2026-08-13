# frozen_string_literal: true

class Receipts::Editing::InputNormalizer
  RECEIPT_INTEGER_FIELDS = %w[total_amount subtotal_amount tax_amount].freeze
  RECEIPT_DECIMAL_FIELDS = %w[tax_rate].freeze
  ITEM_INTEGER_FIELDS = %w[price original_line_total line_total].freeze
  ITEM_QUANTITY_FIELDS = %w[quantity].freeze
  ITEM_REFERENCE_DECIMAL_FIELDS = %w[reference_price_amount reference_quantity].freeze
  ITEM_RAW_UNIT_FIELDS = %w[quantity_unit_raw reference_quantity_unit_raw].freeze
  ITEM_REFERENCE_EVIDENCE_FIELDS = %w[
    reference_price_amount
    reference_quantity
    reference_quantity_unit_code
    reference_quantity_unit_raw
    reference_price_tax_inclusion
  ].freeze
  ITEM_MANUAL_AMOUNT_SOURCE_FIELDS = %w[
    price
    quantity
    quantity_unit_code
    original_line_total
    line_total
    discount_rate
  ].freeze
  ITEM_PERCENTAGE_FIELDS = %w[tax_rate discount_rate].freeze
  ITEM_NULLABLE_SOURCE_FIELDS = %w[
    pricing_source_kind
    reference_price_amount
    reference_quantity
    reference_quantity_unit_code
    quantity_unit_raw
    reference_quantity_unit_raw
    reference_price_tax_inclusion
  ].freeze
  FORMULA_PRICING_SOURCE_KINDS = %w[count_unit_price reference_quantity_price].freeze
  ITEM_DISCOUNT_CLEAR_INTENT_FIELD = "clear_item_discount_before_explicit"
  ADJUSTMENT_REVIEW_TARGET_FIELDS = %i[kind label amount sign tax_rate].freeze

  def self.call(receipt:, attributes:)
    new(receipt: receipt, attributes: attributes).call
  end

  def initialize(receipt:, attributes:)
    @receipt = receipt
    @attributes = attributes.to_h.deep_dup
  end

  def call
    validate_manual_raw_unit_input!
    validate_authority_free_diagnostic_input!
    normalize_explicit_line_total_submission!
    apply_explicit_transition_discount_clear_intents!
    validate_pricing_source_transition!
    normalize_selected_pricing_source_fields!
    normalize_purchased_at!
    normalize_numeric_inputs!
    discard_inferred_discount_rate_echoes!
    validate_unrecorded_explicit_discount_changes!
    normalize_nullable_item_sources!
    normalize_item_quantity_units!
    validate_authority_free_diagnostic_amount_changes!
    normalize_adjustments!
    attributes
  end

  private

  attr_reader :receipt, :attributes

  def validate_manual_raw_unit_input!
    attributes["receipt_items_attributes"]&.each_value do |item|
      existing_item = existing_item_for(item)
      next unless ITEM_RAW_UNIT_FIELDS.any? do |field|
        item.key?(field) && (item[field].present? || existing_item&.public_send(field).present?)
      end

      raise Receipts::Editing::InvalidItemSourceError, "Raw unit evidence is not a manual input"
    end
  end

  def validate_authority_free_diagnostic_input!
    attributes["receipt_items_attributes"]&.each_value do |item|
      submitted_kind = item["pricing_source_kind"].presence if item.key?("pricing_source_kind")
      existing_item = existing_item_for(item)
      effective_kind = item.key?("pricing_source_kind") ? submitted_kind : existing_item&.pricing_source_kind
      next unless effective_kind.nil?
      next unless ITEM_REFERENCE_EVIDENCE_FIELDS.any? do |field|
        item.key?(field) && (item[field].present? || existing_item&.public_send(field).present?)
      end

      raise Receipts::Editing::InvalidItemSourceError, "Diagnostic reference evidence is not a manual source"
    end
  end

  def validate_pricing_source_transition!
    attributes["receipt_items_attributes"]&.each_value do |item|
      next unless item.key?("pricing_source_kind")

      submitted_kind = item["pricing_source_kind"].presence
      existing_item = existing_item_for(item)
      next unless existing_item

      existing_kind = existing_item.pricing_source_kind
      next if submitted_kind == existing_kind
      next if submitted_kind.nil? && existing_kind.nil?

      required_fields = case submitted_kind
      when "count_unit_price"
        %w[price quantity quantity_unit_code]
      when "explicit_line_total"
        %w[original_line_total]
      when "reference_quantity_price"
        %w[
          quantity
          quantity_unit_code
          reference_price_amount
          reference_quantity
          reference_quantity_unit_code
          reference_price_tax_inclusion
        ]
      else
        []
      end

      valid = submitted_kind.present? && required_fields.all? do |field|
        item.key?(field) && item[field].present?
      end
      if submitted_kind == "explicit_line_total"
        valid &&= explicit_transition_discount_contract_valid?(item, existing_item)
      end
      raise Receipts::Editing::InvalidItemSourceError, "Incomplete pricing source transition" unless valid
    end
  end

  def normalize_explicit_line_total_submission!
    attributes["receipt_items_attributes"]&.each_value do |item|
      existing_item = existing_item_for(item)
      effective_kind = if item.key?("pricing_source_kind")
        item["pricing_source_kind"].presence
      else
        existing_item&.pricing_source_kind
      end
      next unless effective_kind == "explicit_line_total"

      if item.key?("original_line_total")
        if item["original_line_total"].present?
          item["line_total"] = item["original_line_total"]
        elsif existing_item.nil?
          item["line_total"] = item["original_line_total"]
        elsif existing_item.original_line_total.nil?
          if effective_positive_discount?(item, existing_item)
            raise Receipts::Editing::InvalidItemSourceError,
              "Explicit line total authority is ambiguous for a discounted item"
          end

          item["line_total"] = existing_item.line_total
        else
          item["line_total"] = item["original_line_total"]
        end
      else
        item.delete("line_total")
      end
    end
  end

  def apply_explicit_transition_discount_clear_intents!
    attributes["receipt_items_attributes"]&.each_value do |item|
      next unless item.key?(ITEM_DISCOUNT_CLEAR_INTENT_FIELD)

      intent = item.delete(ITEM_DISCOUNT_CLEAR_INTENT_FIELD).to_s
      next if intent == "0" || intent.empty?

      existing_item = existing_item_for(item)
      valid = intent == "1" &&
        (existing_item.nil? || FORMULA_PRICING_SOURCE_KINDS.include?(existing_item.pricing_source_kind)) &&
        item["pricing_source_kind"] == "explicit_line_total" &&
        item["original_line_total"].present?
      raise Receipts::Editing::InvalidItemSourceError, "Invalid item discount clear intent" unless valid

      item["discount_amount"] = nil
      if item["discount_rate"].present?
        explicit_discount_replacement_item_ids << item.object_id
      else
        item["discount_rate"] = nil
        discount_clear_intent_item_ids << item.object_id
      end
    end
  end

  def normalize_selected_pricing_source_fields!
    attributes["receipt_items_attributes"]&.each_value do |item|
      next unless item.key?("pricing_source_kind")

      existing_item = existing_item_for(item)
      submitted_kind = item["pricing_source_kind"].presence
      next if existing_item && submitted_kind == existing_item.pricing_source_kind

      case submitted_kind
      when "count_unit_price"
        clear_reference_pricing_fields!(item)
      when "explicit_line_total"
        item["price"] = nil
        clear_reference_pricing_fields!(item)
      when "reference_quantity_price"
        item["price"] = nil
      end
    end
  end

  def clear_reference_pricing_fields!(item)
    ITEM_REFERENCE_EVIDENCE_FIELDS.each { |field| item[field] = nil }
    item["reference_quantity_unit_raw"] = nil
  end

  def explicit_transition_discount_contract_valid?(item, existing_item)
    return !effective_discount_source_present?(item, existing_item) unless formula_pricing_source_record?(existing_item)
    return true unless persisted_discount_source_present?(existing_item)

    discount_clear_intent_item_ids.include?(item.object_id) ||
      explicit_discount_replacement_item_ids.include?(item.object_id)
  end

  def formula_pricing_source_record?(item)
    item && FORMULA_PRICING_SOURCE_KINDS.include?(item.pricing_source_kind)
  end

  def persisted_discount_source_present?(item)
    !item.discount_rate.nil? || !item.discount_amount.nil?
  end

  def discount_clear_intent_item_ids
    @discount_clear_intent_item_ids ||= Set.new
  end

  def explicit_discount_replacement_item_ids
    @explicit_discount_replacement_item_ids ||= Set.new
  end

  def effective_discount_source_present?(item, existing_item)
    %w[discount_rate discount_amount].any? do |field|
      value = item.key?(field) ? item[field] : existing_item.public_send(field)
      value.present?
    end
  end

  def effective_positive_discount?(item, existing_item)
    rate = if item.key?("discount_rate")
      Receipts::NumericInput.percentage(item["discount_rate"])
    else
      existing_item&.discount_rate
    end
    amount = if item.key?("discount_amount")
      Receipts::NumericInput.integer(item["discount_amount"])
    else
      existing_item&.discount_amount
    end

    rate.to_d.positive? || amount.to_i.positive?
  end

  def normalize_purchased_at!
    submitted = attributes.key?("purchased_on") || attributes.key?("purchased_time")
    purchased_on = attributes.delete("purchased_on")
    purchased_time = attributes.delete("purchased_time")

    attributes["purchased_at"] = build_purchased_at(purchased_on, purchased_time) if submitted
  end

  def build_purchased_at(purchased_on, purchased_time)
    return if purchased_on.blank?

    datetime_text = [ purchased_on, purchased_time.presence ].compact.join(" ")
    Time.zone.parse(datetime_text)
  rescue ArgumentError, TypeError
    nil
  end

  def normalize_numeric_inputs!
    normalize_numeric_fields!(attributes, RECEIPT_INTEGER_FIELDS, :integer)
    normalize_numeric_fields!(attributes, RECEIPT_DECIMAL_FIELDS, :decimal)

    attributes["receipt_items_attributes"]&.each_value do |item_attributes|
      normalize_numeric_fields!(item_attributes, ITEM_INTEGER_FIELDS, :integer)
      normalize_numeric_fields!(item_attributes, ITEM_QUANTITY_FIELDS, :decimal)
      normalize_numeric_fields!(item_attributes, ITEM_REFERENCE_DECIMAL_FIELDS, :decimal)
      normalize_numeric_fields!(item_attributes, ITEM_PERCENTAGE_FIELDS, :percentage)
    end

    attributes["receipt_adjustments_attributes"]&.each_value do |adjustment_attributes|
      normalize_numeric_fields!(adjustment_attributes, %w[amount], :integer)
      normalize_numeric_fields!(adjustment_attributes, %w[tax_rate], :percentage)
    end

    attributes["receipt_payments_attributes"]&.each_value do |payment_attributes|
      normalize_numeric_fields!(payment_attributes, %w[amount], :integer)
    end
  end

  def normalize_numeric_fields!(target, fields, parser)
    fields.each do |field|
      next unless target.key?(field)

      target[field] = Receipts::NumericInput.public_send(parser, target[field])
    end
  end

  def discard_inferred_discount_rate_echoes!
    attributes["receipt_items_attributes"]&.each_value do |item|
      next unless item.key?("discount_rate")
      next if explicit_discount_replacement_item_ids.include?(item.object_id)

      existing_item = existing_item_for(item)
      next unless existing_item
      next unless existing_item.discount_rate.nil?
      next unless existing_item.discount_amount.to_i.positive?

      inferred_rate = Receipts::NumericInput.percentage(existing_item.discount_rate_percentage_input)
      item.delete("discount_rate") if item["discount_rate"] == inferred_rate
    end
  end

  def validate_unrecorded_explicit_discount_changes!
    attributes["receipt_items_attributes"]&.each_value do |item|
      existing_item = existing_item_for(item)
      next unless existing_item&.pricing_source_kind == "explicit_line_total"
      next unless existing_item.original_line_total.nil?

      effective_kind = if item.key?("pricing_source_kind")
        item["pricing_source_kind"].presence
      else
        existing_item.pricing_source_kind
      end
      next unless effective_kind == "explicit_line_total"
      next if item.key?("original_line_total") && !item["original_line_total"].nil?

      discount_changed =
        (item.key?("discount_rate") && item["discount_rate"] != existing_item.discount_rate) ||
        (item.key?("discount_amount") && item["discount_amount"] != existing_item.discount_amount)
      next unless discount_changed

      raise Receipts::Editing::InvalidItemSourceError,
        "Discount cannot change without an explicit line total authority"
    end
  end

  def normalize_nullable_item_sources!
    item_attributes = attributes["receipt_items_attributes"]
    return if item_attributes.blank?

    item_attributes.each_value do |item|
      ITEM_NULLABLE_SOURCE_FIELDS.each do |field|
        item[field] = nil if item.key?(field) && item[field].blank?
      end
    end
  end

  def normalize_item_quantity_units!
    item_attributes = attributes["receipt_items_attributes"]
    return if item_attributes.blank?

    item_attributes.each_value do |item|
      next if item["id"].present? && !item.key?("quantity_unit_code")

      if formula_pricing_source?(item)
        item["quantity_unit_code"] = nil if item["quantity_unit_code"].blank?
        next
      end

      raw_code = item["quantity_unit_code"]
      code = if raw_code.blank?
        ReceiptQuantityUnit.default_code
      else
        ReceiptQuantityUnit.normalize(raw_code, default: nil)
      end

      item["quantity_unit_code"] = code || raw_code.to_s
    end
  end

  def validate_authority_free_diagnostic_amount_changes!
    attributes["receipt_items_attributes"]&.each_value do |item|
      existing_item = existing_item_for(item)
      next unless authority_free_diagnostic_record?(existing_item)

      effective_kind = item.key?("pricing_source_kind") ? item["pricing_source_kind"].presence : existing_item.pricing_source_kind
      next unless effective_kind.nil?
      next unless ITEM_MANUAL_AMOUNT_SOURCE_FIELDS.any? do |field|
        item.key?(field) && item[field] != existing_item.public_send(field)
      end

      raise Receipts::Editing::InvalidItemSourceError,
        "Authority-free diagnostic amount source cannot be changed manually"
    end
  end

  def authority_free_diagnostic_record?(item)
    return false unless item
    return false unless item.pricing_source_kind.nil?

    (ITEM_RAW_UNIT_FIELDS + ITEM_REFERENCE_EVIDENCE_FIELDS).any? do |field|
      !item.public_send(field).nil?
    end
  end

  def formula_pricing_source?(item)
    kind = if item.key?("pricing_source_kind")
      item["pricing_source_kind"]
    else
      existing_item_for(item)&.pricing_source_kind
    end

    FORMULA_PRICING_SOURCE_KINDS.include?(kind.to_s)
  end

  def existing_item_for(item)
    id = item["id"].to_s
    return if id.empty?

    existing_items_by_id[id]
  end

  def existing_items_by_id
    @existing_items_by_id ||= receipt&.receipt_items&.index_by { |item| item.id.to_s } || {}
  end

  def normalize_adjustments!
    adjustment_attributes = attributes["receipt_adjustments_attributes"]
    return if adjustment_attributes.blank?

    existing_adjustments = receipt&.receipt_adjustments&.index_by { |adjustment| adjustment.id.to_s } || {}

    adjustment_attributes.each_value do |adjustment|
      existing = existing_adjustments[adjustment["id"].to_s]
      normalize_adjustment_kind_and_sign!(adjustment, existing: existing)
      next if existing && !adjustment_review_target_changed?(existing, adjustment)

      adjustment["source"] = "manual"
      adjustment["needs_review"] = false
      adjustment["review_reasons"] = []
    end
  end

  def normalize_adjustment_kind_and_sign!(adjustment, existing:)
    if existing
      kind_submitted = adjustment.key?("kind")
      sign_submitted = adjustment.key?("sign")
      return unless kind_submitted || sign_submitted

      adjustment["kind"] = ReceiptAdjustment.normalize_kind(adjustment["kind"]) if kind_submitted
      effective_kind = kind_submitted ? adjustment["kind"] : existing.kind
      requested_sign = sign_submitted ? adjustment["sign"] : existing.sign
      adjustment["sign"] = normalized_adjustment_sign(kind: effective_kind, requested_sign: requested_sign)
      return
    end

    adjustment["kind"] = ReceiptAdjustment.normalize_kind(adjustment["kind"])
    adjustment["sign"] = normalized_adjustment_sign(
      kind: adjustment["kind"],
      requested_sign: adjustment["sign"]
    )
  end

  def adjustment_review_target_changed?(adjustment, submitted)
    changed_adjustment = adjustment.dup
    changed_adjustment.assign_attributes(submitted.slice(*ADJUSTMENT_REVIEW_TARGET_FIELDS.map(&:to_s)))

    ADJUSTMENT_REVIEW_TARGET_FIELDS.any? do |field|
      submitted.key?(field.to_s) &&
        comparable_adjustment_review_value(field, changed_adjustment.public_send(field)) !=
          comparable_adjustment_review_value(field, adjustment.public_send(field))
    end
  end

  def comparable_adjustment_review_value(field, value)
    return value.to_s.strip.presence if field == :label

    value
  end

  def normalized_adjustment_sign(kind:, requested_sign:)
    kind = kind.to_s
    requested_sign = requested_sign.to_s

    if kind == "other"
      return requested_sign if ReceiptAdjustment::SIGNS.include?(requested_sign)

      return "surcharge"
    end

    ReceiptAdjustment.default_sign_for(kind)
  end
end
