class ReceiptFormPresenter
  attr_reader :receipt

  def initialize(
    receipt:,
    submitted_params: nil,
    purchase_inputs_changed: false,
    adjustment_tax_detail_evidence_stale: false,
    adjustment_absence_confirmed: false,
    invalid_item_source: false
  )
    @receipt = receipt
    @submitted_params = submitted_params.to_h.with_indifferent_access
    @submitted_values_by_object_id = {}
    @submitted_rows_cache = {}
    @submitted_rows_by_id_cache = {}
    @purchase_inputs_changed = purchase_inputs_changed == true
    @adjustment_tax_detail_evidence_stale = adjustment_tax_detail_evidence_stale == true
    @adjustment_absence_confirmed = adjustment_absence_confirmed == true
    @invalid_item_source = invalid_item_source == true
  end

  def purchase_inputs_changed?
    @purchase_inputs_changed
  end

  def adjustment_tax_detail_evidence_stale?
    @adjustment_tax_detail_evidence_stale
  end

  def adjustment_absence_confirmation_available?
    receipt.persisted? &&
      receipt_review_reason_includes?("adjustment_uncertain") &&
      receipt.receipt_adjustments.none?(&:persisted?)
  end

  def adjustment_absence_confirmation_visible?
    adjustment_absence_confirmation_available? && visible_receipt_adjustments.empty?
  end

  def adjustment_absence_confirmed?
    @adjustment_absence_confirmed && adjustment_absence_confirmation_visible?
  end

  def invalid_item_source?
    @invalid_item_source
  end

  def form_dom_id
    receipt.persisted? ? "edit_receipt_form_#{receipt.public_id}" : "new_receipt_form"
  end

  def visible_receipt_items
    @visible_receipt_items ||= begin
      associated = receipt.receipt_items.reject do |item|
        item.marked_for_destruction? || submitted_destroyed?(:receipt_items_attributes, item)
      end
      associated + submitted_new_items(existing_records: associated.reject(&:persisted?))
    end
  end

  def destroyed_receipt_items
    receipt.receipt_items.select do |item|
      item.marked_for_destruction? || submitted_destroyed?(:receipt_items_attributes, item)
    end
  end

  def visible_receipt_adjustments
    @visible_receipt_adjustments ||= begin
      associated = receipt.receipt_adjustments.reject do |adjustment|
        adjustment.marked_for_destruction? || submitted_destroyed?(:receipt_adjustments_attributes, adjustment)
      end
      associated + submitted_new_adjustments(existing_records: associated.reject(&:persisted?))
    end
  end

  def destroyed_receipt_adjustments
    receipt.receipt_adjustments.select do |adjustment|
      adjustment.marked_for_destruction? || submitted_destroyed?(:receipt_adjustments_attributes, adjustment)
    end
  end

  def visible_receipt_payments
    @visible_receipt_payments ||= begin
      associated = receipt.receipt_payments.reject do |payment|
        payment.marked_for_destruction? || submitted_destroyed?(:receipt_payments_attributes, payment)
      end
      associated + submitted_new_payments(existing_records: associated.reject(&:persisted?))
    end
  end

  def destroyed_receipt_payments
    receipt.receipt_payments.select do |payment|
      payment.marked_for_destruction? || submitted_destroyed?(:receipt_payments_attributes, payment)
    end
  end

  def next_item_index
    [ receipt.receipt_items.size, visible_receipt_items.size ].max
  end

  def next_adjustment_index
    [ receipt.receipt_adjustments.size, visible_receipt_adjustments.size ].max
  end

  def next_payment_index
    [ receipt.receipt_payments.size, visible_receipt_payments.size ].max
  end

  def adjustment_surcharge_kinds_value
    ReceiptAdjustment::SURCHARGE_KINDS.join(",")
  end

  def adjustment_discount_kinds_value
    ReceiptAdjustment::DISCOUNT_KINDS.join(",")
  end

  def adjustment_payment_kinds_value
    ReceiptAmountService.payment_adjustment_kinds.join(",")
  end

  def adjustment_purchase_kinds_value
    ReceiptAmountService.purchase_adjustment_kinds.join(",")
  end

  def adjustment_payment_label_pattern_value
    ReceiptAmountService.payment_adjustment_label_pattern_source
  end

  def adjustment_tax_detail_rates_value
    receipt.receipt_tax_details.each_with_object([]) do |tax_detail, rates|
      next unless tax_detail.amount.to_i.abs + tax_detail.net_amount.to_i.abs > 0

      percentage = tax_detail.rate&.to_d&.*(100)
      rates << if percentage.nil?
        nil
      elsif percentage.frac.zero?
        percentage.to_i.to_s
      else
        percentage.to_s("F")
      end
    end
  end

  def reference_projection_fallback_tax_rate_value
    rate = ReceiptAmountService.reference_projection_fallback_tax_rate(
      receipt_tax_rate: receipt.tax_rate,
      receipt_tax_details: receipt.receipt_tax_details
    )
    return "" if rate.nil?

    percentage = rate * 100
    percentage.frac.zero? ? percentage.to_i.to_s : percentage.to_s("F")
  end

  def reference_pricing_contract_value
    {
      "price_amount_max" => ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX.to_s("F"),
      "price_amount_max_scale" => ReceiptItem::REFERENCE_PRICE_AMOUNT_MAX_SCALE,
      "quantity_max" => ReceiptItem::REFERENCE_QUANTITY_MAX.to_s("F"),
      "quantity_max_scale" => ReceiptItem::REFERENCE_QUANTITY_MAX_SCALE,
      "units" => ReceiptQuantityUnit.allowed_codes.to_h do |code|
        unit = ReceiptQuantityUnit.unit_for(code)
        [
          code,
          {
            "conversion_group" => unit.conversion_group,
            "scale_numerator" => unit.exact_scale.numerator.to_s,
            "scale_denominator" => unit.exact_scale.denominator.to_s,
            "granularity_numerator" => unit.input_granularity.numerator.to_s,
            "granularity_denominator" => unit.input_granularity.denominator.to_s,
            "allowed_pricing_roles" => unit.allowed_pricing_roles.map(&:to_s)
          }
        ]
      end
    }
  end

  def decimal_quantity_units_value
    ReceiptQuantityUnit.decimal_codes.join(",")
  end

  def countable_quantity_units_value
    ReceiptQuantityUnit.countable_codes.join(",")
  end

  def default_quantity_unit_value
    ReceiptQuantityUnit.default_code
  end

  def integer_quantity_step_value
    "1"
  end

  def decimal_quantity_step_value
    "0.001"
  end

  def new_item
    ReceiptItem.new
  end

  def new_adjustment
    ReceiptAdjustment.new(kind: "delivery_fee", sign: "surcharge", source: "manual")
  end

  def new_payment
    ReceiptPayment.new
  end

  def error_flags
    {
      store_name: receipt_review_reason_includes?("store_name_missing", "store_name_uncertain"),
      payment_method: receipt_review_reason_includes?("payment_method_missing", "payment_method_uncertain"),
      purchased_at: receipt_review_reason_includes?(
        "purchased_at_missing",
        "purchased_at_uncertain",
        "purchased_at_conflicted"
      ) || receipt.errors[:purchased_at].any?,
      store_address: receipt_review_reason_includes?("store_address_missing", "store_address_uncertain"),
      store_phone_number: receipt_review_reason_includes?("store_phone_number_missing", "store_phone_number_uncertain")
    }
  end

  def submitted_value(field, fallback: nil)
    submitted_params.key?(field) ? submitted_params[field] : fallback
  end

  def item_row(item, new_record:)
    ItemRowState.new(
      item: item,
      new_record: new_record,
      submitted_values: submitted_child_values(:receipt_items_attributes, item)
    )
  end

  def adjustment_row(adjustment, new_record:)
    AdjustmentRowState.new(
      adjustment: adjustment,
      new_record: new_record,
      submitted_values: submitted_child_values(:receipt_adjustments_attributes, adjustment)
    )
  end

  def payment_row(payment, new_record:)
    PaymentRowState.new(
      payment: payment,
      new_record: new_record,
      submitted_values: submitted_child_values(:receipt_payments_attributes, payment)
    )
  end

  private

  attr_reader :submitted_params, :submitted_values_by_object_id, :submitted_rows_cache, :submitted_rows_by_id_cache

  def submitted_child_values(collection_key, record)
    transient_values = submitted_values_by_object_id[record.object_id]
    return transient_values if transient_values
    return {} unless record.persisted?

    submitted_child_rows_by_id(collection_key)[record.id.to_s] || {}
  end

  def submitted_child_rows(collection_key)
    cache_key = collection_key.to_sym
    return submitted_rows_cache[cache_key] if submitted_rows_cache.key?(cache_key)

    values = submitted_params[collection_key]
    rows = if values.respond_to?(:each_value)
      values.each_value.map { |row| row.to_h.with_indifferent_access }
    else
      []
    end

    submitted_rows_cache[cache_key] = rows
  end

  def submitted_child_rows_by_id(collection_key)
    cache_key = collection_key.to_sym
    return submitted_rows_by_id_cache[cache_key] if submitted_rows_by_id_cache.key?(cache_key)

    submitted_rows_by_id_cache[cache_key] = submitted_child_rows(collection_key).each_with_object({}) do |values, index|
      id = values["id"].to_s
      index[id] ||= values if id.present?
    end
  end

  def submitted_destroyed?(collection_key, record)
    return false unless record.persisted?

    ActiveModel::Type::Boolean.new.cast(submitted_child_values(collection_key, record)["_destroy"])
  end

  def submitted_new_items(existing_records: [])
    build_submitted_rows(:receipt_items_attributes, ReceiptItem, existing_records: existing_records) do |values|
      {
        confirmed_name: values["confirmed_name"],
        category: values["category"],
        quantity_unit_code: values["quantity_unit_code"],
        product_code: values["product_code"]
      }
    end
  end

  def submitted_new_adjustments(existing_records: [])
    build_submitted_rows(:receipt_adjustments_attributes, ReceiptAdjustment, existing_records: existing_records) do |values|
      {
        kind: values["kind"],
        label: values["label"],
        sign: values["sign"],
        source: "manual"
      }
    end
  end

  def submitted_new_payments(existing_records: [])
    build_submitted_rows(:receipt_payments_attributes, ReceiptPayment, existing_records: existing_records) do |values|
      { method: values["method"] }
    end
  end

  def build_submitted_rows(collection_key, record_class, existing_records: [])
    submitted_new_row_index = 0
    submitted_child_rows(collection_key).filter_map do |values|
      next if values["id"].present?
      next if ActiveModel::Type::Boolean.new.cast(values["_destroy"])

      if (record = existing_records[submitted_new_row_index])
        submitted_values_by_object_id[record.object_id] = values
        submitted_new_row_index += 1
        next
      end

      submitted_new_row_index += 1
      record = record_class.new(yield(values))
      submitted_values_by_object_id[record.object_id] = values
      record
    end
  end

  def receipt_review_reason_codes
    @receipt_review_reason_codes ||= Array(receipt.review_reasons).map(&:to_s)
  end

  def receipt_review_reason_includes?(*codes)
    (receipt_review_reason_codes & codes.map(&:to_s)).any?
  end

  class ItemRowState
    attr_reader :item

    def initialize(item:, new_record:, submitted_values: {})
      @item = item
      @new_record = new_record
      @submitted_values = submitted_values
    end

    def new_record?
      @new_record == true
    end

    def item_name
      submitted_value(:confirmed_name) do
        item.confirmed_name.presence || item.suggested_name.presence || item.raw_text.presence || ""
      end
    end

    def warning_reason_labels
      return [] if new_record?

      ReviewReasons.warning_reasons_for_user(review_reason_codes).map do |reason|
        I18n.t("enums.receipt_item.review_reason.#{reason}", default: reason.to_s.humanize)
      end
    end

    def error_flags
      {
        name: review_reason_includes?("item_name_uncertain"),
        category: review_reason_includes?("item_category_uncertain"),
        tax_rate: review_reason_includes?("item_tax_rate_uncertain")
      }
    end

    def row_class
      return "grid grid-cols-2 receipt-form-item-layout gap-4 md:gap-1.5 items-center p-3 rounded-lg receipt-form-item-row transition-colors relative min-w-0" if new_record?

      [
        "grid grid-cols-2 receipt-form-item-layout gap-4 md:gap-1.5 items-center p-3 rounded-lg transition-colors relative min-w-0",
        item.needs_review ? "border receipt-form-item-review-row" : "receipt-form-item-row",
        ("receipt-form-item-details-open" if pricing_source_review?)
      ].compact.join(" ")
    end

    def line_total_value
      submitted_value(:line_total) { new_record? ? nil : item.line_total }
    end

    def original_line_total_value
      submitted_value(:original_line_total) do
        if new_record?
          nil
        elsif item.original_line_total.to_i.positive?
          item.original_line_total.to_i
        elsif !item.line_total.nil?
          item.line_total
        else
          nil
        end
      end
    end

    def line_total_data
      source_value = if pricing_source_ui_mode == "explicit_line_total"
        explicit_line_total_value
      else
        original_line_total_value
      end
      data = {
        receipt_form_target: "lineTotalInput",
        original_line_total: source_value
      }
      data[:original_saved_line_total] = line_total_value unless new_record? || line_total_value.nil?
      data
    end

    def selected_unit
      submitted_value(:quantity_unit_code) do
        new_record? ? ReceiptQuantityUnit.default_code : item.normalized_quantity_unit_code
      end
    end

    def quantity_value
      value = submitted_value(:quantity) do
        new_record? ? "1" : (item.formatted_quantity_for_input.presence || "1")
      end
      return "" if value.nil? && submitted_values.key?(:quantity)

      value
    end

    def quantity_step
      ReceiptItem.quantity_step_for(selected_unit)
    end

    def quantity_inputmode
      ReceiptItem.quantity_inputmode_for(selected_unit)
    end

    def quantity_unit_options
      ReceiptItem.quantity_unit_options
    end

    def price_value
      return submitted_values[:price] if submitted_values.key?(:price)
      return nil if new_record?

      normalized_tax_included_price || item.price
    end

    def pricing_source_kind_value
      return submitted_values[:pricing_source_kind].presence if submitted_values.key?(:pricing_source_kind)
      return "count_unit_price" if new_record?

      item.pricing_source_kind.presence
    end

    def pricing_source_ui_mode
      pricing_source_kind_value || "unclassified"
    end

    def pricing_source_mode_options
      %w[count_unit_price reference_quantity_price explicit_line_total].map do |kind|
        [ I18n.t("receipts.item_fields.pricing_modes.#{kind}"), kind ]
      end
    end

    def pricing_mode_active?(*modes)
      modes.map(&:to_s).include?(pricing_source_ui_mode)
    end

    def reference_price_amount_value
      submitted_value(:reference_price_amount) do
        new_record? ? nil : decimal_input_value(item.reference_price_amount)
      end
    end

    def reference_quantity_value
      submitted_value(:reference_quantity) do
        new_record? ? nil : decimal_input_value(item.reference_quantity)
      end
    end

    def selected_reference_quantity_unit
      submitted_value(:reference_quantity_unit_code) do
        if new_record?
          selected_unit
        else
          item.reference_quantity_unit_code.presence || selected_unit
        end
      end
    end

    def reference_quantity_step
      ReceiptItem.quantity_step_for(selected_reference_quantity_unit)
    end

    def reference_quantity_inputmode
      ReceiptItem.quantity_inputmode_for(selected_reference_quantity_unit)
    end

    def reference_price_tax_inclusion_value
      submitted_value(:reference_price_tax_inclusion) do
        if new_record?
          "gross"
        else
          item.reference_price_tax_inclusion.presence || "gross"
        end
      end
    end

    def reference_price_tax_inclusion_label
      I18n.t(
        "receipts.item_fields.reference_price_tax_inclusions.#{reference_price_tax_inclusion_value}",
        default: reference_price_tax_inclusion_value
      )
    end

    def explicit_line_total_value
      if submitted_values.key?(:original_line_total)
        submitted_amount = submitted_values[:original_line_total]
        return submitted_amount unless submitted_amount.blank?
        return submitted_amount unless item.original_line_total.nil?
        return nil if effective_positive_discount?

        return item.line_total
      end
      return nil if new_record?
      return item.original_line_total unless item.original_line_total.nil?
      return nil if effective_positive_discount?

      item.line_total
    end

    def explicit_line_total_source_missing?
      pricing_source_ui_mode == "explicit_line_total" &&
        explicit_line_total_value.blank? &&
        effective_positive_discount?
    end

    def clear_item_discount_before_explicit_value
      submitted_value(:clear_item_discount_before_explicit) { "0" }
    end

    def explicit_line_total_label
      key = discount_source_present? ? :explicit_line_total_before_discount : :explicit_line_total
      I18n.t("receipts.item_fields.#{key}")
    end

    def discount_source_present?
      if pricing_source_ui_mode == "explicit_line_total" &&
        clear_item_discount_before_explicit_value.to_s == "1"
        return submitted_values.key?(:discount_rate) && submitted_values[:discount_rate].to_s.strip.present?
      end
      if submitted_values.key?(:discount_rate)
        return true if submitted_values[:discount_rate].to_s.strip.present?
        return true if persisted_explicit_positive_discount_rate_source?

        return !item.discount_amount.nil?
      end

      !item.discount_rate.nil? || !item.discount_amount.nil?
    end

    def persisted_formula_discount_input_value
      return nil if new_record?
      return nil unless %w[count_unit_price reference_quantity_price].include?(item.pricing_source_kind)

      item.discount_rate_percentage_input
    end

    def persisted_absolute_discount_source?
      return false if new_record?

      item.discount_rate.nil? && !item.discount_amount.nil?
    end

    def persisted_explicit_positive_discount_rate_source?
      return false if new_record?
      return false unless item.pricing_source_kind == "explicit_line_total"
      return false unless item.original_line_total.nil?

      item.discount_rate.to_d.positive?
    end

    def pricing_source_summary_for(mode)
      case mode.to_s
      when "count_unit_price"
        count_unit_price_summary
      when "reference_quantity_price"
        reference_quantity_price_summary
      when "explicit_line_total"
        explicit_line_total_summary
      else
        unclassified_pricing_summary
      end
    end

    def pricing_source_summary_template_for(mode)
      key = case mode.to_s
      when "count_unit_price"
        "count_unit_price"
      when "reference_quantity_price"
        "reference_quantity_price"
      when "explicit_line_total"
        discount_source_present? ? "explicit_line_total_before_discount" : "explicit_line_total"
      end
      return nil unless key

      I18n.t("receipts.item_fields.pricing_summaries.#{key}")
    end

    def pricing_source_summary_unset_for(mode)
      case mode.to_s
      when "count_unit_price"
        I18n.t("receipts.item_fields.pricing_summaries.count_unit_price_unset")
      when "reference_quantity_price"
        I18n.t("receipts.item_fields.pricing_summaries.reference_quantity_price_unset")
      when "explicit_line_total"
        explicit_line_total_label
      end
    end

    def pricing_source_kind_highlight_variant
      item.errors[:pricing_source_kind].any? || pricing_source_review? ? :error : nil
    end

    def pricing_source_review?
      item.needs_review && review_reason_includes?("item_pricing_mode_uncertain")
    end

    def reference_price_amount_highlight_variant
      item.errors[:reference_price_amount].any? ? :error : nil
    end

    def reference_quantity_highlight_variant
      item.errors[:reference_quantity].any? || item.errors[:reference_quantity_unit_code].any? ? :error : nil
    end

    def discount_rate_percentage_input
      submitted_value(:discount_rate) { new_record? ? nil : item.discount_rate_percentage_input }
    end

    def tax_rate_percentage_value
      submitted_value(:tax_rate) { item.tax_rate.present? ? item.tax_rate * 100 : nil }
    end

    def category_options
      ReceiptItem.category_options
    end

    def selected_category
      submitted_value(:category) { item.category }
    end

    def name_highlight_variant
      item.needs_review && error_flags[:name] ? :error : nil
    end

    def quantity_highlight_variant
      item.errors[:quantity].any? ? :error : nil
    end

    def price_highlight_variant
      item.errors[:price].any? ? :error : nil
    end

    def discount_rate_highlight_variant
      item.errors[:discount_rate].any? ? :error : nil
    end

    def tax_rate_highlight_variant
      item.errors[:tax_rate].any? || (item.needs_review && error_flags[:tax_rate]) ? :error : nil
    end

    def category_highlight_variant
      item.needs_review && error_flags[:category] ? :error : nil
    end

    private

    attr_reader :submitted_values

    def submitted_value(field)
      return submitted_values[field] if submitted_values.key?(field)

      yield
    end

    def review_reason_codes
      @review_reason_codes ||= Array(item.review_reasons).map(&:to_s)
    end

    def review_reason_includes?(*codes)
      (review_reason_codes & codes.map(&:to_s)).any?
    end

    def count_unit_price_summary
      price = price_value
      quantity = quantity_value
      return I18n.t("receipts.item_fields.pricing_summaries.count_unit_price_unset") if price.blank? || quantity.blank?

      I18n.t(
        "receipts.item_fields.pricing_summaries.count_unit_price",
        price: display_decimal(price),
        quantity: display_decimal(quantity),
        unit: ReceiptQuantityUnit.label(selected_unit)
      )
    end

    def reference_quantity_price_summary
      amount = reference_price_amount_value
      quantity = reference_quantity_value
      unit = selected_reference_quantity_unit
      if amount.blank? || quantity.blank? || unit.blank?
        return I18n.t("receipts.item_fields.pricing_summaries.reference_quantity_price_unset")
      end

      I18n.t(
        "receipts.item_fields.pricing_summaries.reference_quantity_price",
        amount: display_decimal(amount),
        quantity: display_decimal(quantity),
        unit: ReceiptQuantityUnit.label(unit),
        tax_inclusion: short_tax_inclusion_label
      )
    end

    def explicit_line_total_summary
      amount = explicit_line_total_value
      return explicit_line_total_label if amount.blank?

      I18n.t(
        discount_source_present? ?
          "receipts.item_fields.pricing_summaries.explicit_line_total_before_discount" :
          "receipts.item_fields.pricing_summaries.explicit_line_total",
        amount: display_decimal(amount)
      )
    end

    def effective_positive_discount?
      if clear_item_discount_before_explicit_value.to_s == "1"
        return submitted_values.key?(:discount_rate) && positive_decimal?(submitted_values[:discount_rate])
      end
      if submitted_values.key?(:discount_rate)
        return true if positive_decimal?(submitted_values[:discount_rate])
        return true if persisted_explicit_positive_discount_rate_source?

        return item.discount_amount.to_i.positive?
      end

      item.discount_rate.to_d.positive? || item.discount_amount.to_i.positive?
    end

    def positive_decimal?(value)
      BigDecimal(value.to_s.delete("%")).positive?
    rescue ArgumentError
      false
    end

    def unclassified_pricing_summary
      if ReceiptQuantityUnit.countable?(selected_unit) && price_value.present? && quantity_value.present?
        return I18n.t(
          "receipts.item_fields.pricing_summaries.unclassified_count",
          price: display_decimal(price_value),
          quantity: display_decimal(quantity_value),
          unit: ReceiptQuantityUnit.label(selected_unit)
        )
      end
      if line_total_value.present?
        return I18n.t(
          "receipts.item_fields.pricing_summaries.unclassified_saved_total",
          amount: display_decimal(line_total_value)
        )
      end

      I18n.t("receipts.item_fields.pricing_summaries.unclassified_amount_missing")
    end

    def short_tax_inclusion_label
      I18n.t(
        "receipts.item_fields.reference_price_tax_inclusions_short.#{reference_price_tax_inclusion_value}",
        default: reference_price_tax_inclusion_value
      )
    end

    def decimal_input_value(value)
      return nil if value.nil?
      return value.to_s("F").sub(/\.?0+\z/, "") if value.is_a?(BigDecimal)

      value.to_s
    end

    def display_decimal(value)
      decimal_input_value(value)
    rescue ArgumentError
      value.to_s
    end

    def normalized_tax_included_price
      return nil if item.price.blank? || item.original_line_total.blank? || item.line_total.blank?
      return nil if item.tax_rate.blank? || !item.tax_rate.to_d.positive?
      return nil if discount_applied?
      return nil if ReceiptItem.decimal_quantity_unit?(selected_unit)

      quantity = item.quantity.presence || BigDecimal("1")
      quantity = BigDecimal(quantity.to_s)
      return nil unless quantity.positive? && quantity.frac.zero?

      original_total = item.original_line_total.to_i
      gross_total = item.line_total.to_i
      return nil unless original_total.positive? && gross_total.positive?
      return nil if original_total == gross_total
      return nil unless item.price.to_i == exact_unit_amount(original_total, quantity)

      exact_unit_amount(gross_total, quantity)
    rescue ArgumentError
      nil
    end

    def exact_unit_amount(total, quantity)
      quantity_integer = quantity.to_i
      return nil unless quantity_integer.positive?
      return nil unless (total % quantity_integer).zero?

      total / quantity_integer
    end

    def discount_applied?
      item.discount_amount.to_i.positive? || (item.discount_rate.present? && item.discount_rate.to_d.positive?)
    end
  end

  class AdjustmentRowState
    attr_reader :adjustment

    def initialize(adjustment:, new_record:, submitted_values: {})
      @adjustment = adjustment
      @new_record = new_record
      @submitted_values = submitted_values
    end

    def new_record?
      @new_record == true
    end

    def selected_kind
      submitted_value(:kind) { adjustment.kind.presence }
    end

    def selected_sign
      submitted_value(:sign) { adjustment.sign.presence || ReceiptAdjustment.default_sign_for(selected_kind) }
    end

    def other_kind?
      selected_kind == "other"
    end

    def tax_rate_value
      submitted_value(:tax_rate) { adjustment.tax_rate.present? ? adjustment.tax_rate * 100 : nil }
    end

    def label_value
      submitted_value(:label) { adjustment.label }
    end

    def amount_value
      submitted_value(:amount) { adjustment.amount }
    end

    def calculation_effect
      ReceiptAmountService.adjustment_effect(classification_input)
    end

    def source_text_payment_adjustment?
      pattern = Regexp.new(ReceiptAmountService.payment_adjustment_label_pattern_source, Regexp::IGNORECASE)
      adjustment.source_text.to_s.match?(pattern)
    end

    def source_non_manual?
      adjustment.source.to_s != "manual"
    end

    def kind_options
      ReceiptAdjustment.kind_options
    end

    def sign_options
      ReceiptAdjustment.sign_options
    end

    def sign_label
      I18n.t("enums.receipt_adjustment.sign.#{selected_sign}", default: selected_sign)
    end

    def sign_label_wrapper_class
      "hidden" if other_kind?
    end

    def sign_select_wrapper_class
      "hidden" unless other_kind?
    end

    def sign_select_disabled?
      !other_kind?
    end

    private

    attr_reader :submitted_values

    def classification_input
      adjustment.attributes.symbolize_keys.merge(
        kind: selected_kind,
        label: label_value,
        sign: selected_sign
      )
    end

    def submitted_value(field)
      return submitted_values[field] if submitted_values.key?(field)

      yield
    end
  end

  class PaymentRowState
    attr_reader :payment

    def initialize(payment:, new_record:, submitted_values: {})
      @payment = payment
      @new_record = new_record
      @submitted_values = submitted_values
    end

    def new_record?
      @new_record == true
    end

    def method_value
      submitted_value(:method) { new_record? ? nil : payment.method }
    end

    def amount_value
      submitted_value(:amount) { new_record? ? nil : payment.amount }
    end

    private

    attr_reader :submitted_values

    def submitted_value(field)
      return submitted_values[field] if submitted_values.key?(field)

      yield
    end
  end
end
