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
end
