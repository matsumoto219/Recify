module ReceiptsHelper
  # 電話番号表示用（日本向けフォーマット）
  def display_phone_number(phone_number)
    return "未登録" if phone_number.blank?

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

  def receipt_item_discount_label(item)
    discount_amount = item.discount_amount.to_i
    return nil unless discount_amount.positive?

    label = "#{t('receipts.show.discount')}: -¥#{number_with_delimiter(discount_amount)}"
    original_line_total = item.original_line_total.to_i
    return label unless original_line_total.positive?
    return label if discount_amount > original_line_total

    percentage = BigDecimal(discount_amount.to_s) * 100 / BigDecimal(original_line_total.to_s)
    formatted_percentage = number_with_precision(percentage, precision: 1, strip_insignificant_zeros: true)
    "#{label}（#{formatted_percentage}%）"
  end
end
