module ReceiptFallbackPatterns
  # OCRフォールバック用の簡易ルール（AI失敗時のみ使用）
  # NOTE: 上から順に評価（先にマッチしたものを採用）
  # NOTE: OCRテキストは normalize 済み前提（全角→半角 / 小文字 / 余分な空白除去）
  # NOTE: このファイルでは「簡易分類ルール」のみを担当する
  #       - 支払い方法: レシート全体の raw_text / lines から判定
  #       - カテゴリ: 明細単位の raw_text から判定
  # NOTE: フォールバック保存時も自動確定はせず、needs_review = true 前提で扱う

  PAYMENT_METHOD_PATTERNS = {
    "credit_card" => /master|mastercard|visa|jcb|amex|american\s*express|diners|discover|uc|dc/i,
    "debit_card" => /デビット|debit/i,
    "cash" => /現金|cash|お釣り|おつり|釣銭|預り|お預り/i,
    "e_money" => /suica|pasmo|icoca|waon|nanaco|edy|楽天edy|id|quickpay|quicpay/i,
    "qr_payment" => /paypay|楽天ペイ|楽天pay|rakuten\s*pay|d払い|d payment|au\s*pay|aupay|メルペイ|line\s*pay/i,
    "other" => /.*/
  }.freeze

  CATEGORY_PATTERNS = {
    "drink" => /ｺｰﾋｰ|コーヒー|お茶|tea|coffee|ジュース|水/,
    "food" => /ｻﾝﾄﾞ|サンド|パン|弁当|おにぎり|ラーメン|うどん/,
    "daily_goods" => /ティッシュ|洗剤|シャンプー/,
    "household" => /キッチン|ラップ|スポンジ|洗濯|掃除/,
    "medical" => /薬|ドラッグ|病院|処方/,
    "beauty" => /化粧|コスメ/,
    "transportation" => /電車|バス|タクシー/,
    "hobby" => /雑誌|本|ゲーム|玩具|ホビー/,
    "other" => /.*/
  }.freeze

  module_function

  def detect_payment_method(text)
    detect_by_patterns(text, PAYMENT_METHOD_PATTERNS)
  end

  def detect_category(text)
    detect_by_patterns(text, CATEGORY_PATTERNS)
  end

  def detect_by_patterns(text, patterns)
    normalized_text = text.to_s

    patterns.each do |key, pattern|
      return key if normalized_text.match?(pattern)
    end

    nil
  end
end
