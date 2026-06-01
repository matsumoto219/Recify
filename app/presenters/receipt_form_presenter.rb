class ReceiptFormPresenter
  attr_reader :receipt

  def initialize(receipt:)
    @receipt = receipt
  end

  def form_dom_id
    receipt.persisted? ? "edit_receipt_form_#{receipt.public_id}" : "new_receipt_form"
  end

  def visible_receipt_items
    receipt.receipt_items.reject(&:marked_for_destruction?)
  end

  def destroyed_receipt_items
    receipt.receipt_items.select(&:marked_for_destruction?)
  end

  def visible_receipt_adjustments
    receipt.receipt_adjustments.reject(&:marked_for_destruction?)
  end

  def destroyed_receipt_adjustments
    receipt.receipt_adjustments.select(&:marked_for_destruction?)
  end

  def next_item_index
    receipt.receipt_items.size
  end

  def next_adjustment_index
    receipt.receipt_adjustments.size
  end

  def adjustment_surcharge_kinds_value
    ReceiptAdjustment::SURCHARGE_KINDS.join(",")
  end

  def adjustment_discount_kinds_value
    ReceiptAdjustment::DISCOUNT_KINDS.join(",")
  end

  def decimal_quantity_units_value
    ReceiptItem::DECIMAL_QUANTITY_UNITS.join(",")
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

  def item_row(item, new_record:)
    ItemRowState.new(item: item, new_record: new_record)
  end

  def adjustment_row(adjustment, new_record:)
    AdjustmentRowState.new(adjustment: adjustment, new_record: new_record)
  end

  private

  def receipt_review_reason_codes
    @receipt_review_reason_codes ||= Array(receipt.review_reasons).map(&:to_s)
  end

  def receipt_review_reason_includes?(*codes)
    (receipt_review_reason_codes & codes.map(&:to_s)).any?
  end

  class ItemRowState
    attr_reader :item

    def initialize(item:, new_record:)
      @item = item
      @new_record = new_record
    end

    def new_record?
      @new_record == true
    end

    def item_name
      item.confirmed_name.presence || item.suggested_name.presence || item.raw_text.presence || ""
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
      new_record? ? nil : item.line_total
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
      new_record? ? ReceiptItem::DEFAULT_QUANTITY_UNIT : item.quantity_unit.presence || ReceiptItem::DEFAULT_QUANTITY_UNIT
    end

    def quantity_value
      new_record? ? "1" : (item.formatted_quantity_for_input.presence || "1")
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

    def discount_rate_percentage_input
      new_record? ? nil : item.discount_rate_percentage_input
    end

    def tax_rate_percentage_value
      item.tax_rate.present? ? item.tax_rate * 100 : nil
    end

    def category_options
      ReceiptItem.category_options
    end

    def selected_category
      new_record? ? nil : item.category
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

    def review_reason_codes
      @review_reason_codes ||= Array(item.review_reasons).map(&:to_s)
    end

    def review_reason_includes?(*codes)
      (review_reason_codes & codes.map(&:to_s)).any?
    end
  end

  class AdjustmentRowState
    attr_reader :adjustment

    def initialize(adjustment:, new_record:)
      @adjustment = adjustment
      @new_record = new_record
    end

    def new_record?
      @new_record == true
    end

    def selected_kind
      adjustment.kind.presence
    end

    def selected_sign
      adjustment.sign.presence || ReceiptAdjustment.default_sign_for(selected_kind)
    end

    def other_kind?
      selected_kind == "other"
    end

    def tax_rate_value
      adjustment.tax_rate.present? ? adjustment.tax_rate * 100 : nil
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
  end
end
