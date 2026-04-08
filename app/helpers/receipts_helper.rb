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
end
