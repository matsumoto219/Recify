module Analysis
  module ReceiptFallbackPatterns
    # OCRフォールバック用の簡易ルール（AI失敗時のみ使用）
    # NOTE: 上から順に評価（先にマッチしたものを採用）
    # NOTE: このファイルでは「簡易分類ルール」のみを担当する
    # NOTE: フォールバック保存時も自動確定はせず、needs_review = true 前提で扱う

    PAYMENT_METHOD_PATTERNS = {
      "debit_card" => [
        /デビット(?:カード)?/i,
        /debit(?:\s*card)?/i,
        /j[-\s]?debit/i,
        /visa\s*debit/i
      ],
      "credit_card" => [
        /クレジット(?:カード)?/i,
        /credit(?:\s*card)?/i,
        /master(?:card)?/i,
        /visa(?!\s*debit)/i,
        /jcb/i,
        /amex/i,
        /american\s*express/i,
        /diners/i,
        /discover/i,
        /uc/i,
        /dc/i,
        /銀聯/i,
        /union\s*pay/i
      ],
      "qr_payment" => [
        /paypay/i,
        /楽天(?:ペイ|pay)/i,
        /rakuten\s*pay/i,
        /d払い/i,
        /d\s*payment/i,
        /au\s*pay/i,
        /aupay/i,
        /メルペイ/i,
        /line\s*pay/i,
        /linepay/i,
        /alipay/i,
        /wechat\s*pay/i
      ],
      "e_money" => [
        /suica/i,
        /pasmo/i,
        /icoca/i,
        /waon(?!\s*point)/i,
        /nanaco/i,
        /楽天edy/i,
        /\bedy\b/i,
        /\bid\b/i,
        /quick\s*pay/i,
        /quic\s*pay/i,
        /apple\s*pay/i,
        /google\s*pay/i
      ],
      "cash" => [
        /現金/i,
        /cash/i,
        /お釣り/i,
        /おつり/i,
        /釣銭/i,
        /預り/i,
        /お預り/i,
        /現計/i
      ]
    }.freeze

    CATEGORY_PATTERNS = {
      "drink" => [
        /ｺｰﾋｰ/i,
        /コーヒー/i,
        /焙煎コーヒー/i,
        /カフェラテ/i,
        /ラテ/i,
        /お茶/i,
        /tea/i,
        /coffee/i,
        /ジュース/i,
        /オレンジジュース/i,
        /牛乳/i,
        /ミルク/i,
        /天然水/i,
        /ミネラルウォーター/i,
        /(?:\A|[[:space:]])水[[:space:]]*\d+(?:ml|l)\b/i,
        /(?:\A|[[:space:]])水[[:space:]]*[\(（]飲料[\)）]/i,
        /炭酸/i,
        /酒/i,
        /ビール/i
      ],
      "food" => [
        /ｻﾝﾄﾞ/i,
        /サンド/i,
        /パン/i,
        /弁当/i,
        /おにぎり/i,
        /ラーメン/i,
        /うどん/i,
        /牛丼/i,
        /惣菜/i,
        /豆腐/i,
        /野菜/i,
        /魚/i,
        /肉/i,
        /バナナ/i,
        /ミニトマト/i,
        /トマト/i,
        /たまご/i,
        /卵/i,
        /ヨーグルト/i,
        /米/i,
        /じゃがいも/i,
        /もやし/i,
        /かぼちゃ/i,
        /サラダ/i,
        /パスタ/i,
        /ハンバーグ/i,
        /コロッケ/i,
        /ごはん/i,
        /ゼリー/i,
        /プリン/i,
        /シュークリーム/i,
        /チーズ/i,
        /チキン/i,
        /鶏/i,
        /豚/i,
        /牛/i,
        /サーモン/i,
        /海老/i,
        /エビ/i,
        /クッキー/i
      ],
      "daily_goods" => [
        /乾電池/i,
        /ティッシュ/i,
        /やわらかティッシュ/i,
        /洗剤/i,
        /シャンプー/i,
        /歯ブラシ/i,
        /石鹸/i,
        /トイレットペーパー/i
      ],
      "household" => [
        /キッチン/i,
        /ラップ/i,
        /スポンジ/i,
        /洗濯/i,
        /掃除/i,
        /電球/i,
        /収納/i
      ],
      "medical" => [
        /薬/i,
        /ドラッグ/i,
        /病院/i,
        /処方/i,
        /湿布/i,
        /マスク/i
      ],
      "beauty" => [
        /化粧/i,
        /コスメ/i,
        /美容/i,
        /乳液/i,
        /化粧水/i
      ],
      "transportation" => [
        /電車/i,
        /バス/i,
        /タクシー/i,
        /駐車/i,
        /高速(?:道路|料金|代)/i,
        /ガソリン/i
      ],
      "hobby" => [
        /雑誌/i,
        /書籍/i,
        /文庫/i,
        /単行本/i,
        /コミック/i,
        /ゲーム/i,
        /玩具/i,
        /ホビー/i,
        /文具/i,
        /ノート/i,
        /ボールペン/i,
        /クリアファイル/i,
        /修正テープ/i
      ]
    }.freeze

    PAYMENT_METHOD_EXCLUSION_PATTERNS = [
      /ポイント/i,
      /point/i,
      /会員/i,
      /member/i,
      /waon\s*point/i,
      /楽天ポイント/i,
      /tポイント/i,
      /dポイント/i,
      /ponta/i
    ].freeze

    module_function

    def detect_payment_method(text)
      normalized_text = normalize_text(text)
      return nil if normalized_text.blank?
      return nil if payment_noise_only?(normalized_text)

      detect_by_patterns(normalized_text, PAYMENT_METHOD_PATTERNS) || "other"
    end

    def detect_category(text)
      normalized_text = normalize_text(text)
      return nil if normalized_text.blank?

      detect_by_patterns(normalized_text, CATEGORY_PATTERNS) || "other"
    end

    def detect_by_patterns(text, patterns)
      patterns.each do |key, pattern_list|
        Array(pattern_list).each do |pattern|
          return key if text.match?(pattern)
        end
      end

      nil
    end

    def normalize_text(text)
      return nil if text.blank?

      text.to_s.unicode_normalize(:nfkc).downcase.gsub(/[[:space:]]+/, " ").strip.presence
    end

    def payment_noise_only?(text)
      has_exclusion = PAYMENT_METHOD_EXCLUSION_PATTERNS.any? { |pattern| text.match?(pattern) }
      has_payment_signal = detect_by_patterns(text, PAYMENT_METHOD_PATTERNS).present?

      has_exclusion && !has_payment_signal
    end
  end
end
