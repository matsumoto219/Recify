module ReceiptFallbackPatterns
  # OCRフォールバック用の簡易ルール（AI失敗時のみ使用）

  PAYMENT_METHOD_PATTERNS = {
    "credit_card" => /Master|VISA|JCB|AMEX/i,
    "cash" => /現金/,
    "e_money" => /Suica|PASMO|ICOCA|WAON|nanaco/i,
    "qr_payment" => /PayPay|楽天ペイ|d払い|au PAY/i
  }.freeze

  CATEGORY_PATTERNS = {
    "drink" => /ｺｰﾋｰ|コーヒー|お茶|tea|coffee|ジュース|水/,
    "food" => /ｻﾝﾄﾞ|サンド|パン|弁当|おにぎり|ラーメン|うどん/,
    "daily_goods" => /ティッシュ|洗剤|シャンプー/
  }.freeze
end
