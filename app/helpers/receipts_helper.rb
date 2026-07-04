module ReceiptsHelper
  ReceiptNotesState = Struct.new(:groups, :items, :count, keyword_init: true)
  AmountSummaryTaxDetailRow = Struct.new(
    :rate_label,
    :amount_display,
    :net_amount_display,
    :total_display,
    keyword_init: true
  )
  ReceiptIndexCountSummaryParts = Struct.new(:total_text, :range_text, :full_text, keyword_init: true)

  RECEIPT_REVIEW_TARGET_BASIC_INFO = "receipt-section-basic-info".freeze
  RECEIPT_REVIEW_TARGET_ITEMS = "receipt-section-items".freeze
  RECEIPT_REVIEW_TARGET_ADJUSTMENTS = "receipt-section-adjustments".freeze
  RECEIPT_REVIEW_TARGET_PAYMENTS = "receipt-section-payments".freeze
  RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY = "receipt-section-amount-summary".freeze
  RECEIPT_REVIEW_TARGET_IMAGE_PREVIEW = "receipt-section-image-preview".freeze
  RECEIPT_REVIEW_TARGET_ITEM_PREFIX = "receipt-item".freeze
  RECEIPT_REVIEW_TARGET_ITEM_ID_PREFIX = "#{RECEIPT_REVIEW_TARGET_ITEM_PREFIX}-".freeze

  REVIEW_REASON_TARGET_ANCHORS = {
    "store_name_missing" => RECEIPT_REVIEW_TARGET_BASIC_INFO,
    "store_name_uncertain" => RECEIPT_REVIEW_TARGET_BASIC_INFO,
    "store_address_missing" => RECEIPT_REVIEW_TARGET_BASIC_INFO,
    "store_address_uncertain" => RECEIPT_REVIEW_TARGET_BASIC_INFO,
    "store_phone_number_missing" => RECEIPT_REVIEW_TARGET_BASIC_INFO,
    "store_phone_number_uncertain" => RECEIPT_REVIEW_TARGET_BASIC_INFO,
    "purchased_at_missing" => RECEIPT_REVIEW_TARGET_BASIC_INFO,
    "purchased_at_uncertain" => RECEIPT_REVIEW_TARGET_BASIC_INFO,
    "purchased_at_conflicted" => RECEIPT_REVIEW_TARGET_BASIC_INFO,
    "item_name_uncertain" => RECEIPT_REVIEW_TARGET_ITEMS,
    "item_category_uncertain" => RECEIPT_REVIEW_TARGET_ITEMS,
    "item_quantity_uncertain" => RECEIPT_REVIEW_TARGET_ITEMS,
    "item_tax_rate_uncertain" => RECEIPT_REVIEW_TARGET_ITEMS,
    "items_missing" => RECEIPT_REVIEW_TARGET_ITEMS,
    "item_total_mismatch" => RECEIPT_REVIEW_TARGET_ITEMS,
    "item_tax_rate_group_uncertain" => RECEIPT_REVIEW_TARGET_ITEMS,
    "zero_amount_item_incomplete" => RECEIPT_REVIEW_TARGET_ITEMS,
    "discount_data_incomplete" => RECEIPT_REVIEW_TARGET_ADJUSTMENTS,
    "adjustment_uncertain" => RECEIPT_REVIEW_TARGET_ADJUSTMENTS,
    "adjustment_tax_rate_missing" => RECEIPT_REVIEW_TARGET_ADJUSTMENTS,
    "payment_method_missing" => RECEIPT_REVIEW_TARGET_PAYMENTS,
    "payment_method_uncertain" => RECEIPT_REVIEW_TARGET_PAYMENTS,
    "payment_amount_mismatch" => RECEIPT_REVIEW_TARGET_PAYMENTS,
    "total_mismatch" => RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY,
    "tax_amount_mismatch" => RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY,
    "tax_detail_mismatch" => RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY,
    "tax_detail_rate_mismatch" => RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY,
    "tax_detail_incomplete" => RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY,
    "tax_detail_partial" => RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY,
    "ocr_total_mismatch" => RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY,
    "price_tax_inclusion_uncertain" => RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY,
    "calculation_profile_uncertain" => RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY,
    "invalid_amount_relation" => RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY,
    "tax_details_double_counted" => RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY,
    "tax_detail_gross_item_mismatch" => RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY,
    "insufficient_data" => RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY,
    "ocr_unreadable" => RECEIPT_REVIEW_TARGET_IMAGE_PREVIEW,
    "ocr_low_confidence" => RECEIPT_REVIEW_TARGET_IMAGE_PREVIEW,
    "multiple_receipts_suspected" => RECEIPT_REVIEW_TARGET_IMAGE_PREVIEW
  }.freeze
  REVIEW_REASON_TARGET_LINK_CLASS = "ui-touch-control inline-flex shrink-0 self-start text-xs font-bold transition-colors".freeze

  RECEIPT_INDEX_SORT_OPTIONS = %w[
    newest
    oldest
    amount_desc
    amount_asc
    store_name
    updated
    review_priority
  ].freeze
  RECEIPT_INDEX_PER_PAGE_OPTIONS = [ 20, 50, 100 ].freeze

  def receipt_dom_id(receipt)
    receipt.dom_target_id
  end

  # 電話番号表示用（日本向けフォーマット）
  def display_phone_number(phone_number)
    return t("receipts.common.unregistered") if phone_number.blank?

    normalized = phone_number.to_s

    # +81形式 → 0始まりに変換
    if normalized.start_with?("+81")
      domestic = "0" + normalized.delete_prefix("+81")
      return domestic if domestic.match?(/\A0\d+\z/)
    end

    normalized
  end

  # アップロード可能な画像形式（file_field の accept 用）
  def receipt_image_accept
    "image/jpeg,image/png,image/bmp,image/tiff,image/heif,image/heic,.jpg,.jpeg,.png,.bmp,.tif,.tiff,.heif,.heic"
  end

  def receipt_total_amount_display(amount, currency_prefix: "¥")
    return t("receipts.common.unset") if amount.nil?

    "#{currency_prefix}#{number_with_delimiter(amount)}"
  end

  def receipt_detail_amount_display(amount, currency_prefix: "¥")
    return t("receipts.common.not_available") if amount.nil?

    "#{currency_prefix}#{number_with_delimiter(amount)}"
  end

  def receipt_signed_amount_display(amount, currency_prefix: "¥")
    return t("receipts.common.not_available") if amount.nil?

    signed_amount = amount.to_i
    sign = signed_amount.negative? ? "-" : "+"
    "#{sign}#{receipt_detail_amount_display(signed_amount.abs, currency_prefix: currency_prefix)}"
  end

  def receipt_payment_adjustment_summary(receipt)
    ReceiptAmountService.payment_adjustment_summary(receipt: receipt)
  end

  def receipt_rate_display(rate)
    return t("receipts.common.not_available") if rate.nil?
    return rate if rate.is_a?(String) && rate.include?("%")

    percentage = BigDecimal(rate.to_s) * 100
    "#{number_with_precision(percentage, precision: 1, strip_insignificant_zeros: true)}%"
  rescue ArgumentError
    rate.to_s.presence || t("receipts.common.not_available")
  end

  def receipt_tax_rate_summary(receipt, items: nil, tax_details: nil)
    tax_detail_rates = normalized_receipt_tax_detail_rates(tax_details || receipt.receipt_tax_details)
    return t("receipts.common.multiple_tax_rates") if tax_detail_rates.many?
    return receipt_rate_display(tax_detail_rates.first) if tax_detail_rates.one?

    item_rates = normalized_receipt_item_tax_rates(items || receipt.receipt_items)
    return nil if item_rates.empty?
    return receipt_rate_display(item_rates.first) if item_rates.one?

    t("receipts.common.multiple_tax_rates")
  end

  def receipt_amount_summary_tax_detail_rows(tax_details, currency_prefix: "¥")
    Array(tax_details).map do |tax_detail|
      rate = read_receipt_value(tax_detail, :rate)
      net_amount = read_receipt_value(tax_detail, :net_amount)
      amount = read_receipt_value(tax_detail, :amount)
      total = amount.nil? || net_amount.nil? ? nil : net_amount.to_i + amount.to_i

      AmountSummaryTaxDetailRow.new(
        rate_label: receipt_rate_display(rate),
        amount_display: receipt_detail_amount_display(amount, currency_prefix: currency_prefix),
        net_amount_display: receipt_detail_amount_display(net_amount, currency_prefix: currency_prefix),
        total_display: receipt_detail_amount_display(total, currency_prefix: currency_prefix)
      )
    end
  end

  def receipt_index_sort_options
    RECEIPT_INDEX_SORT_OPTIONS.map do |value|
      [ t("receipts.index.controls.sort_options.#{value}"), value ]
    end
  end

  def receipt_index_per_page_options
    RECEIPT_INDEX_PER_PAGE_OPTIONS.map do |value|
      [ t("receipts.index.controls.per_page_options.count", count: value), value.to_s ]
    end
  end

  def receipt_index_count_summary_parts(summary)
    total = number_with_delimiter(receipt_index_count_summary_value(summary, :total))
    start_number = number_with_delimiter(receipt_index_count_summary_value(summary, :start))
    finish_number = number_with_delimiter(receipt_index_count_summary_value(summary, :finish))

    ReceiptIndexCountSummaryParts.new(
      total_text: t("receipts.index.controls.count_total", total: total),
      range_text: t("receipts.index.controls.count_range", start: start_number, finish: finish_number),
      full_text: t("receipts.index.controls.count_summary", total: total, start: start_number, finish: finish_number)
    )
  end

  def receipt_item_discount_label(item)
    discount_amount = item.discount_amount.to_i
    return nil unless discount_amount.positive?

    label = "#{t('receipts.show.discount')}: -¥#{number_with_delimiter(discount_amount)}"
    original_line_total = item.original_line_total.to_i
    return label unless original_line_total.positive?
    return label if discount_amount > original_line_total

    percentage =
      if item.discount_rate.present?
        BigDecimal(item.discount_rate.to_s) * 100
      else
        BigDecimal(discount_amount.to_s) * 100 / BigDecimal(original_line_total.to_s)
      end
    formatted_percentage = number_with_precision(percentage, precision: 1, strip_insignificant_zeros: true)
    "#{label}（#{formatted_percentage}%）"
  end

  def receipt_item_warning_reason_codes(item)
    ReviewReasons.warning_reasons_for_user(Array(item.review_reasons).map(&:to_s))
  end

  def receipt_item_warning_reason_labels(item)
    receipt_item_warning_reason_codes(item).map do |reason|
      t("enums.receipt_item.review_reason.#{reason}", default: reason.to_s.humanize)
    end
  end

  def review_reason_target(reason)
    normalized = ReviewReasons.normalize(reason)
    return nil unless ReviewReasons.user_facing_reason?(normalized)

    REVIEW_REASON_TARGET_ANCHORS[normalized]
  end

  def receipt_review_item_target_id(item)
    return nil unless item.respond_to?(:id) && item.id.present?

    "#{RECEIPT_REVIEW_TARGET_ITEM_ID_PREFIX}#{item.id}"
  end

  def review_reason_target_anchor(reason, item: nil)
    target = review_reason_target(reason)
    return nil if target.blank?

    item_target = receipt_review_item_target_id(item)
    return item_target if target == RECEIPT_REVIEW_TARGET_ITEMS && item_target.present?

    target
  end

  def review_reason_target_path(reason, base_path: nil, item: nil)
    target = review_reason_target_anchor(reason, item: item)
    return nil if target.blank?

    base_path.present? ? "#{base_path}##{target}" : "##{target}"
  end

  def review_reason_target_link(reason, base_path: nil, variant: :primary, item: nil)
    target_path = review_reason_target_path(reason, base_path: base_path, item: item)
    return nil if target_path.blank?

    target = review_reason_target(reason)
    anchor_target = review_reason_target_anchor(reason, item: item)
    item_target = receipt_review_item_target_id(item)
    data = {
      turbo: false,
      review_reason_target_link: true,
      review_reason_code: ReviewReasons.normalize(reason),
      review_reason_target: target,
      review_reason_anchor_target: anchor_target
    }
    data[:review_reason_target_item] = item_target if item_target.present? && anchor_target == item_target

    render(
      "shared/ui/actions/button",
      as: :link,
      href: target_path,
      label: t("receipts.review_notes_card.confirm_link"),
      variant: variant,
      unstyled: true,
      class: REVIEW_REASON_TARGET_LINK_CLASS,
      data: data
    )
  end

  def receipt_review_notes_state(receipt)
    groups = grouped_receipt_review_reasons(receipt.blocking_review_reason_codes)
    items = receipt.review_items

    ReceiptNotesState.new(
      groups: groups,
      items: items,
      count: groups.values.sum(&:size) + items.size
    )
  end

  def receipt_warning_notes_state(receipt)
    groups = grouped_receipt_review_reasons(receipt.warning_review_reason_codes)

    ReceiptNotesState.new(
      groups: groups,
      items: [],
      count: groups.values.sum(&:size)
    )
  end

  private

  def receipt_index_count_summary_value(summary, key)
    return summary[key] if summary.respond_to?(:key?) && summary.key?(key)
    return summary[key.to_s] if summary.respond_to?(:key?) && summary.key?(key.to_s)

    summary.public_send(key)
  end

  def grouped_receipt_review_reasons(reason_codes)
    ReviewReasons.group_by_source(reason_codes).select { |_source, reasons| reasons.any? }
  end

  def normalized_receipt_tax_detail_rates(tax_details)
    Array(tax_details).filter_map do |tax_detail|
      normalize_receipt_display_rate(read_receipt_rate(tax_detail, :rate))
    end.uniq
  end

  def normalized_receipt_item_tax_rates(items)
    Array(items).filter_map do |item|
      normalize_receipt_display_rate(read_receipt_rate(item, :tax_rate))
    end.uniq
  end

  def read_receipt_rate(record, key)
    read_receipt_value(record, key)
  end

  def read_receipt_value(record, key)
    return record.public_send(key) if record.respond_to?(key)
    return record[key] if record.respond_to?(:key?) && record.key?(key)
    return record[key.to_s] if record.respond_to?(:key?) && record.key?(key.to_s)

    nil
  end

  def normalize_receipt_display_rate(rate)
    return nil if rate.blank?

    normalized = BigDecimal(rate.to_s)
    normalized > 1 ? normalized / 100 : normalized
  rescue ArgumentError, TypeError
    nil
  end
end
