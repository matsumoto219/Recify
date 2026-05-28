# TODO: 明細行の表示状態判定を整理する。
# needs_review / warning / validation error を view で直接判定せず、
# :normal / :warning / :review / :error のような row variant に集約する。

module ReceiptsHelper
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

  def receipt_rate_display(rate)
    return t("receipts.common.not_available") if rate.nil?
    return rate if rate.is_a?(String) && rate.include?("%")

    percentage = BigDecimal(rate.to_s) * 100
    "#{number_with_precision(percentage, precision: 1, strip_insignificant_zeros: true)}%"
  rescue ArgumentError
    rate.to_s.presence || t("receipts.common.not_available")
  end

  def receipt_item_discount_label(item)
    discount_amount = item.discount_amount.to_i
    return nil unless discount_amount.positive?

    label = "#{t('receipts.show.discount')}: -¥#{number_with_delimiter(discount_amount)}"
    original_line_total = item.original_line_total.to_i
    return label unless original_line_total.positive?
    return label if discount_amount > original_line_total

    percentage = if item.discount_rate.present?
      BigDecimal(item.discount_rate.to_s) * 100
    else
      BigDecimal(discount_amount.to_s) * 100 / BigDecimal(original_line_total.to_s)
    end
    formatted_percentage = number_with_precision(percentage, precision: 1, strip_insignificant_zeros: true)
    "#{label}（#{formatted_percentage}%）"
  end

  def receipt_item_warning_reason_codes(item)
    ReviewReasonSource.warning_reasons_for_user(Array(item.review_reasons).map(&:to_s))
  end

  def receipt_item_warning_reason_labels(item)
    receipt_item_warning_reason_codes(item).map do |reason|
      t("enums.receipt_item.review_reason.#{reason}", default: reason.to_s.humanize)
    end
  end
end
