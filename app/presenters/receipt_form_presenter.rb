class ReceiptFormPresenter
  attr_reader :receipt

  def initialize(receipt:, submitted_params: nil)
    @receipt = receipt
    @submitted_params = submitted_params.to_h.with_indifferent_access
    @submitted_values_by_object_id = {}
  end

  def form_dom_id
    receipt.persisted? ? "edit_receipt_form_#{receipt.public_id}" : "new_receipt_form"
  end

  def visible_receipt_items
    @visible_receipt_items ||= begin
      persisted = receipt.receipt_items.reject(&:marked_for_destruction?)
      persisted + submitted_new_items
    end
  end

  def destroyed_receipt_items
    receipt.receipt_items.select(&:marked_for_destruction?)
  end

  def visible_receipt_adjustments
    @visible_receipt_adjustments ||= begin
      persisted = receipt.receipt_adjustments.reject(&:marked_for_destruction?)
      persisted + submitted_new_adjustments
    end
  end

  def destroyed_receipt_adjustments
    receipt.receipt_adjustments.select(&:marked_for_destruction?)
  end

  def visible_receipt_payments
    @visible_receipt_payments ||= begin
      persisted = receipt.receipt_payments.reject(&:marked_for_destruction?)
      persisted + submitted_new_payments
    end
  end

  def destroyed_receipt_payments
    receipt.receipt_payments.select(&:marked_for_destruction?)
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

  attr_reader :submitted_params, :submitted_values_by_object_id

  def submitted_child_values(collection_key, record)
    transient_values = submitted_values_by_object_id[record.object_id]
    return transient_values if transient_values
    return {} unless record.persisted?

    submitted_child_rows(collection_key).find do |values|
      values["id"].to_s == record.id.to_s
    end || {}
  end

  def submitted_child_rows(collection_key)
    values = submitted_params[collection_key]
    return [] unless values.respond_to?(:each_value)

    values.each_value.map { |row| row.to_h.with_indifferent_access }
  end

  def submitted_new_items
    build_submitted_rows(:receipt_items_attributes, ReceiptItem) do |values|
      {
        confirmed_name: values["confirmed_name"],
        category: values["category"],
        quantity_unit_code: values["quantity_unit_code"],
        product_code: values["product_code"]
      }
    end
  end

  def submitted_new_adjustments
    build_submitted_rows(:receipt_adjustments_attributes, ReceiptAdjustment) do |values|
      {
        kind: values["kind"],
        label: values["label"],
        sign: values["sign"],
        source: "manual"
      }
    end
  end

  def submitted_new_payments
    build_submitted_rows(:receipt_payments_attributes, ReceiptPayment) do |values|
      { method: values["method"] }
    end
  end

  def build_submitted_rows(collection_key, record_class)
    submitted_child_rows(collection_key).filter_map do |values|
      next if values["id"].present?
      next if ActiveModel::Type::Boolean.new.cast(values["_destroy"])

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
      return "grid grid-cols-2 md:grid-cols-12 gap-4 items-center p-3 rounded-lg receipt-form-item-row transition-colors relative min-w-0" if new_record?

      [
        "grid grid-cols-2 md:grid-cols-12 gap-4 items-center p-3 rounded-lg transition-colors relative min-w-0",
        item.needs_review ? "border receipt-form-item-review-row" : "receipt-form-item-row"
      ].join(" ")
    end

    def line_total_value
      submitted_value(:line_total) { new_record? ? nil : item.line_total }
    end

    def original_line_total_value
      new_record? ? 0 : (item.original_line_total.presence || item.line_total.to_i)
    end

    def line_total_data
      data = {
        receipt_form_target: "lineTotalInput",
        original_line_total: original_line_total_value
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
      submitted_value(:quantity) do
        new_record? ? "1" : (item.formatted_quantity_for_input.presence || "1")
      end
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
      submitted_value(:category) { new_record? ? nil : item.category }
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
      ReceiptAmountService.adjustment_effect(adjustment)
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
