class Receipts::Editing::AmountResultApplicator
  def self.call(...)
    new(...).call
  end

  def initialize(receipt:, attributes:, amount_result:, context:, change_set:, tax_details_recalculated:)
    @receipt = receipt
    @attributes = attributes
    @amount_result = amount_result
    @context = context
    @change_set = change_set
    @tax_details_recalculated = tax_details_recalculated
  end

  def call
    resolved = amount_result[:resolved]
    attributes["subtotal_amount"] = resolved[:subtotal]
    attributes["tax_amount"] = resolved[:tax]
    attributes["total_amount"] = resolved[:total]
    attributes["tax_rate"] = resolved[:tax_rate]
    attributes["amount_calculation_profile"] = ReceiptAmountService.calculation_profile_snapshot(amount_result)
    apply_item_totals!(persistence_items)
    if replace_receipt_tax_details?
      attributes["receipt_tax_details_attributes"] = receipt_tax_detail_attributes(amount_result[:tax_details])
    end

    attributes
  end

  private

  attr_reader :receipt, :attributes, :amount_result, :context, :change_set, :tax_details_recalculated

  def persistence_items
    candidate_items = amount_result.dig(:computed, :items)
    return candidate_items unless context == :edit_save
    return [] if receipt_input_without_item_amounts?

    source_items = amount_result.dig(:computed, :source_items)
    source_items.nil? ? candidate_items : source_items
  end

  def receipt_input_without_item_amounts?
    return false unless fetch_value(fetch_value(amount_result, :computed), :amount_engine_basis).to_s == "receipt_input_preserved"

    !submitted_item_amount_source_present? && !normalized_source_item_amount_present?
  end

  def submitted_item_amount_source_present?
    item_attributes = attributes["receipt_items_attributes"]
    return false unless item_attributes.respond_to?(:each_value)

    item_attributes.each_value.any? do |item|
      next false if ActiveModel::Type::Boolean.new.cast(item["_destroy"])

      value_present?(item["price"]) ||
        value_present?(item["line_total"]) ||
        positive_amount?(item["original_line_total"]) ||
        positive_amount?(item["discount_amount"])
    end
  end

  def normalized_source_item_amount_present?
    source_items = Array(fetch_value(fetch_value(amount_result, :computed), :source_items))
    source_items.any? do |item|
      value_present?(fetch_value(item, :price)) ||
        value_present?(fetch_value(item, :amount_persisted_line_total)) ||
        fetch_value(item, :amount_price_present) == true ||
        fetch_value(item, :amount_line_total_present) == true ||
        positive_amount?(fetch_value(item, :original_line_total)) ||
        positive_amount?(fetch_value(item, :amount_persisted_original_line_total)) ||
        positive_amount?(fetch_value(item, :discount_amount)) ||
        positive_amount?(fetch_value(item, :amount_persisted_discount_amount)) ||
        positive_amount?(fetch_value(item, :line_total))
    end
  end

  def value_present?(value)
    !value.nil? && value.to_s.strip != ""
  end

  def positive_amount?(value)
    ReceiptAmountService.parse_amount(value).positive?
  end

  def apply_item_totals!(calculated_items)
    items_attributes = attributes["receipt_items_attributes"]
    return if items_attributes.blank?

    calculated_items = Array(calculated_items)
    return if calculated_items.empty?

    valid_item_attrs = items_attributes.values.reject do |item_attr|
      item_attr.blank? || ActiveModel::Type::Boolean.new.cast(item_attr["_destroy"])
    end

    valid_item_attrs.each_with_index do |item_attr, index|
      calculated_item = calculated_items[index]
      next if calculated_item.blank?

      quantity = calculated_item_value(calculated_item, :quantity)
      price = calculated_item_value(calculated_item, :price)
      line_total = calculated_item_value(calculated_item, :line_total)
      original_line_total = calculated_item_value(calculated_item, :original_line_total)
      discount_amount = calculated_item_value(calculated_item, :discount_amount)
      discount_rate = calculated_item_value(calculated_item, :discount_rate)

      item_attr["quantity"] = quantity if calculated_item_key?(calculated_item, :quantity) && !quantity.nil?
      item_attr["price"] = price if calculated_item_key?(calculated_item, :price) && !price.nil?
      item_attr["line_total"] = line_total if calculated_item_key?(calculated_item, :line_total) && !line_total.nil?
      item_attr["original_line_total"] = original_line_total unless original_line_total.nil?
      item_attr["discount_amount"] = discount_amount if calculated_item_key?(calculated_item, :discount_amount)
      item_attr["discount_rate"] = discount_rate if calculated_item_key?(calculated_item, :discount_rate)
    end
  end

  def calculated_item_value(calculated_item, key)
    return calculated_item[key] if calculated_item.key?(key)

    calculated_item[key.to_s]
  end

  def calculated_item_key?(calculated_item, key)
    calculated_item.key?(key) || calculated_item.key?(key.to_s)
  end

  def fetch_value(value, key)
    return nil unless value.respond_to?(:key?)
    return value[key] if value.key?(key)

    value[key.to_s]
  end

  def receipt_tax_detail_attributes(tax_details)
    destroy_existing_receipt_tax_details + build_receipt_tax_detail_attributes(tax_details)
  end

  def destroy_existing_receipt_tax_details
    receipt.receipt_tax_details.map do |tax_detail|
      {
        "id" => tax_detail.id,
        "_destroy" => "1"
      }
    end
  end

  def build_receipt_tax_detail_attributes(tax_details)
    Array(tax_details).map do |tax_detail|
      {
        "description" => tax_detail[:description],
        "amount" => tax_detail[:amount],
        "rate" => tax_detail[:rate],
        "net_amount" => tax_detail[:net_amount]
      }
    end
  end

  def replace_receipt_tax_details?
    context != :edit_save || change_set&.purchase_amounts_changed? || tax_details_recalculated
  end
end
