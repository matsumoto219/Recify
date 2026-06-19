module ReceiptAnalysisProfiles
  module Japan
    COUNTRY_CODES = %w[JPN].freeze
    CASH_LABEL = "現金"
    VOUCHER_LABEL = "商品券"
    POINT_USAGE_LABEL = "ポイント利用"

    QUANTITY_UNIT_ALIASES = {
      "個" => "each",
      "点" => "item",
      "本" => "piece",
      "袋" => "bag",
      "枚" => "sheet",
      "台" => "unit",
      "箱" => "box",
      "セット" => "set",
      "g" => "gram",
      "グラム" => "gram",
      "kg" => "kilogram",
      "キログラム" => "kilogram",
      "mg" => "milligram",
      "ミリグラム" => "milligram",
      "L" => "liter",
      "l" => "liter",
      "リットル" => "liter",
      "ml" => "milliliter",
      "mL" => "milliliter",
      "ミリリットル" => "milliliter",
      "cc" => "cubic_centimeter"
    }.freeze

    FALLBACK_PAYMENT_METHOD_PATTERNS = {
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
        /master\s*card/i,
        /visa(?!\s*debit)/i,
        /jcb/i,
        /amex/i,
        /american\s*express/i,
        /diners/i,
        /discover/i,
        /uc/i,
        /dc/i,
        /銀聯/i,
        /unionpay/i,
        /union\s*pay/i
      ],
      "qr_payment" => [
        /qr\s*(?:コード)?\s*(?:決済|支払|支払い|payment)?/i,
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
        /交通系\s*ic/i,
        /交通系電子マネー/i,
        /電子マネー/i,
        /waon(?!\s*point)/i,
        /nanaco/i,
        /楽天edy/i,
        /\bedy\b/i,
        /(?<![A-Za-z0-9])i\s*d(?![A-Za-z0-9])/i,
        /quick\s*pay/i,
        /quic\s*pay/i,
        /qui\s*c\s*pay/i,
        /contactless/i,
        /タッチ決済/i,
        /コンタクトレス/i,
        /\bnfc\b/i,
        /mobile\s*payment/i,
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
        /現\s*計/i
      ]
    }.freeze

    FALLBACK_ITEM_CATEGORY_PATTERNS = {
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

    FALLBACK_PAYMENT_METHOD_EXCLUSION_PATTERNS = [
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

    FALLBACK_PAYMENT_METHOD_SUPPORT_ONLY_PATTERNS = [
      /対応/i,
      /使えます/i,
      /使える/i,
      /利用可/i,
      /ご利用(?:いただけます|できます|可能)/i,
      /取扱/i,
      /取り扱/i,
      /accepted/i,
      /available/i,
      /supported/i,
      /we\s+accept/i
    ].freeze

    FALLBACK_PAYMENT_METHOD_TRANSACTION_CONTEXT_PATTERN = /
      支払|お支払|支払い|決済|会計|精算|売上|利用額|支払額|payment|paid|tender|settlement|charge
    /ix.freeze

    OCR_PAYMENT_METHOD_PATTERN = /現金|cash|商品券|金券|ギフト券|お買物券|買物券|voucher|gift\s*certificate|gift\s*card|coupon|クレジット|credit|visa|mastercard|mastercard|master|jcb|amex|american\s*express|diners|discover|unionpay|union\s*pay|銀聯|suica|pasmo|icoca|交通系ic|交通系電子マネー|電子マネー|waon|nanaco|楽天edy|edy|\bid\b|quickpay|quicpay|contactless|タッチ決済|コンタクトレス|\bnfc\b|mobilepayment|applepay|googlepay|qr\s*(?:コード)?\s*(?:決済|支払|支払い|payment)?|paypay|楽天ペイ|rakuten\s*pay|d払い|dpayment|au\s*pay|aupay|メルペイ|line\s*pay|linepay|alipay|wechatpay|デビット|debit/i.freeze
    OCR_POINT_KEYWORDS_PATTERN = /ポイント|point|会員|member|楽天ポイント|楽天ポイン|waonpoint|tポイント|dポイント|ponta/i.freeze
    OCR_PAYMENT_KEYWORDS_PATTERN = /現金|cash|クレジット|credit|visa|mastercard|master|jcb|amex|americanexpress|diners|discover|unionpay|銀聯|suica|pasmo|icoca|交通系ic|交通系電子マネー|電子マネー|waon|nanaco|edy|id|quickpay|quicpay|contactless|タッチ決済|コンタクトレス|nfc|mobilepayment|applepay|googlepay|qr(?:コード)?|paypay|楽天ペイ|rakutenpay|d払い|dpayment|aupay|メルペイ|linepay|alipay|wechatpay|デビット|debit|カード|支払|決済/i.freeze
    OCR_PAYMENT_SUPPORT_ONLY_PATTERN = /対応|使えます|使える|利用可|ご利用(?:いただけます|できます|可能)|取扱|取り扱|accepted|available|supported|weaccept/i.freeze
    OCR_PAYMENT_TRANSACTION_CONTEXT_PATTERN = /支払|お支払|支払い|決済|会計|精算|売上|利用額|支払額|payment|paid|tender|settlement|charge/i.freeze
    OCR_CASH_TOTAL_PATTERN = /現計|現金計|現金合計/.freeze
    OCR_VOUCHER_PAYMENT_PATTERN = /商品券|金券|ギフト券|お買物券|買物券|voucher|giftcertificate|giftcard|coupon/i.freeze
    OCR_SETTLEMENT_LINE_PATTERN = /お預かり|お預り|預かり|預り|現金預り|お釣り|釣銭|つり銭|返金/.freeze
    OCR_ADJUSTMENT_DISCOUNT_LABEL_PATTERN = /返品|返金|取消|キャンセル|値引|割引|クーポン|coupon|discount|refund|return/i.freeze
    OCR_ADJUSTMENT_SURCHARGE_LABEL_PATTERN = /深夜|サービス料|配送料|送料|レジ袋|袋代|手数料|チャージ|fee|charge|surcharge|delivery|shipping|bag|handling/i.freeze
    OCR_ADJUSTMENT_EXCLUDED_LINE_PATTERN = /小計|商品小計|合計|総合計|税抜合計|税込合計|対象|消費税|税額|税率|内税|外税|お預かり|お預り|預り|釣銭|お釣り|つり銭|支払|お支払|決済|現金|カード|au\s*pay|paypay|楽天ペイ|ポイント|獲得|利用可能|残高|カード番号|取引番号|レシート|領収|tel|電話|住所|登録番号|返品はお受け|返品.*(?:不可|致しかね)|お受け致しかね|barcode|qr|total|subtotal|tax|payment|change|point/i.freeze
    OCR_ADJUSTMENT_ZONE_START_PATTERN = /小計|商品小計|税抜合計|内税品計|subtotal/i.freeze
    OCR_ADJUSTMENT_ZONE_END_PATTERN = /合計|総合計|total/i.freeze
    OCR_MERCHANT_ANCHOR_PATTERN = /店舗|店名|店|マーケット|スーパー|株式会社|有限会社|住所|所在地|電話|tel|market|store|mart|shop/i.freeze
    OCR_DATETIME_ANCHOR_PATTERN = /(?:\d{4}[\/\-年]\s*\d{1,2}[\/\-月]\s*\d{1,2}日?)|(?:\d{1,2}[:：]\d{2})/.freeze
    OCR_SUBTOTAL_ANCHOR_PATTERN = /小\s*計|subtotal/i.freeze
    OCR_TOTAL_ANCHOR_PATTERN = /合\s*計|総合計|total/i.freeze
    OCR_TAX_ANCHOR_PATTERN = /消費税|税額|税率|税込|税抜|外税|内税|tax/i.freeze
    OCR_PAYMENT_ANCHOR_PATTERN = /支払|お支払|決済|現金|クレジット|visa|master|jcb|預り|お預り|釣|お釣り|釣銭|pay/i.freeze
    OCR_GENERIC_TAX_DETAIL_DESCRIPTION_PATTERN = /\A(?:内)?消費税等?\z|\A税額\z|\Atax\z/i.freeze
    OCR_TAX_TARGET_MARKER_PATTERN = /対象/.freeze
    OCR_TAX_AMOUNT_DESCRIPTION_PATTERN = /消費税|税額|tax/i.freeze
    OCR_TAX_CONTEXT_LABEL_PATTERN = /小\s*計|対象|消費税|税額|内税|外税|税抜|税込|tax/i.freeze
    OCR_ITEM_DISCOUNT_KEYWORD_PATTERN = /値引|割引|discount/i.freeze
    OCR_TOTAL_AMOUNT_LINE_PATTERN = /合計|小計|total|税込|現計/i.freeze
    OCR_SUBTOTAL_AMOUNT_LINE_PATTERN = /小計|subtotal|税抜/i.freeze
    OCR_CARD_SLIP_CONTEXT_PATTERN = /クレジットカード売上票|カード会社|お支払方法|支払方法|payment method/i.freeze
    OCR_PAYMENT_RESULT_CONTEXT_PATTERN = /支払|決済|payment/i.freeze
    OCR_RECEIPT_LEVEL_DISCOUNT_LINE_PATTERN = /クーポン|会員|夜間|ポイント|アプリ|coupon|member|point/i.freeze
    OCR_ITEM_DISCOUNT_LINE_PATTERN = /値引|割引|discount|off/i.freeze

    ANALYSIS_FALLBACK_PAYMENT_LINE_PATTERN = /現金|現\s*計|cash(?:\s*total)?|商品券|金券|ギフト券|お買物券|買物券|株主優待券|優待券|gift\s*certificate|gift\s*card|voucher|クレジット|credit|visa|master|mastercard|master\s*card|jcb|amex|american express|diners|discover|unionpay|union\s*pay|銀聯|suica|pasmo|icoca|交通系\s*ic|交通系電子マネー|waon|nanaco|楽天edy|edy|(?<![A-Za-z0-9])i\s*d(?![A-Za-z0-9])|quickpay|quicpay|qui\s*c\s*pay|contactless|タッチ決済|コンタクトレス|nfc|mobile payment|apple pay|google pay|qr\s*(?:コード)?\s*(?:決済|支払|支払い|payment)?|paypay|楽天ペイ|rakuten pay|d払い|d payment|au pay|aupay|メルペイ|line pay|linepay|alipay|wechat pay|wechatpay|デビット|debit|電子マネー/i.freeze
    ANALYSIS_FALLBACK_PAYMENT_ACTION_PATTERN = /支払|お支払|支払い|決済|会計|精算|売上|利用額|支払額|現金|現\s*計|cash(?:\s*total)?|商品券|金券|ギフト券|お買物券|買物券|株主優待券|優待券|gift\s*certificate|gift\s*card|voucher|クレジット|credit|電子マネー|suica|pasmo|icoca|交通系\s*ic|交通系電子マネー|waon|nanaco|楽天edy|edy|(?<![A-Za-z0-9])i\s*d(?![A-Za-z0-9])|quickpay|quicpay|qui\s*c\s*pay|contactless|タッチ決済|コンタクトレス|nfc|mobile payment|apple pay|google pay|qr\s*(?:コード)?\s*(?:決済|支払|支払い|payment)?|paypay|楽天ペイ|d払い|d payment|au pay|aupay|メルペイ|line pay|linepay|alipay|wechat pay|wechatpay|デビット|debit|payment|paid|tender|settlement|charge/i.freeze
    ANALYSIS_FALLBACK_PAYMENT_EXCLUDED_PATTERN = /ポイント|point|クーポン|coupon|還元|値引|割引|お釣り|おつり|釣銭|預り|お預り|残高|番号|会員|member/i.freeze
    ANALYSIS_FALLBACK_PAYMENT_SUPPORT_ONLY_PATTERN = /対応|使えます|使える|利用可|ご利用(?:いただけます|できます|可能)|取扱|取り扱|accepted|available|supported|we\s+accept/i.freeze
    ANALYSIS_FALLBACK_PAYMENT_TRANSACTION_CONTEXT_PATTERN = /支払|お支払|支払い|決済|会計|精算|売上|利用額|支払額|現\s*計|cash\s*total|payment|paid|tender|settlement|charge/i.freeze
    ANALYSIS_FALLBACK_PAYMENT_AMOUNT_LABEL_PATTERN = /金額|合計金額|利用額|支払額|お支払額|売上金額|amount|total\s*amount|payment\s*amount/i.freeze
    ANALYSIS_FALLBACK_PAYMENT_METADATA_LABEL_PATTERN = /カード会社|カード番号|端末番号|伝票番号|承認番号|処理通番|商品区分|取扱区分|会員番号|有効期限|加盟店名|merchant|approval|terminal/i.freeze
    ANALYSIS_FALLBACK_PAYMENT_AMOUNT_NOISE_PATTERN = /住所|所在地|丁目|番地|登録番号|事業者番号|伝票番号|処理番号|処理通番|承認番号|取引番号|レシート番号|カード番号|会員番号|端末番号|電話|tel|phone|〒|郵便|レジ\s*#?\s*\d|加盟店名|店舗|店名|支店|\d+\s*号店|merchant|address|approval|terminal|member/i.freeze
    ANALYSIS_FALLBACK_PAYMENT_ADDRESS_AMOUNT_NOISE_PATTERN = /(?:都|道|府|県).*\d|(?:市|区|町|村).*\d/.freeze
    ANALYSIS_VOUCHER_PAYMENT_PATTERN = /商品券|金券|ギフト券|お買物券|買物券|株主優待券|優待券|gift\s*certificate|gift\s*card|voucher/i.freeze
    ANALYSIS_POINT_PAYMENT_LINE_PATTERN = /ポイント\s*(?:利用|支払|払い|決済)|point\s*(?:redemption|payment|used|use|redeemed)|points?\s*(?:redemption|payment|used|redeemed)/i.freeze
    ANALYSIS_POINT_PAYMENT_STRONG_LINE_PATTERN = /ポイント\s*(?:支払|払い|決済)|point\s*(?:redemption|payment|redeemed)|points?\s*(?:redemption|payment|redeemed)/i.freeze
    ANALYSIS_POINT_DISPLAY_LINE_PATTERN = /獲得ポイント|現在ポイント|保有ポイント|ポイント残高|スマイルポイント|付与ポイント|earned\s*points?|current\s*points?|points?\s*balance/i.freeze
    ANALYSIS_PAYMENT_BLOCK_ANCHOR_PATTERN = /お支払い方法|お支払方法|支払方法|payment\s*method|payment|tender|settlement/i.freeze
    ANALYSIS_EXPLICIT_PAYMENT_MONEY_PATTERN = /[¥￥]\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)|(?:\d{1,3}(?:[,，]\d{3})+|\d+)\s*円/.freeze
    ANALYSIS_CASH_DEPOSIT_LABEL_PATTERN = /お\s*預\s*(?:かり|り)|預\s*(?:かり|り)/i.freeze
    ANALYSIS_CASH_CHANGE_LABEL_PATTERN = /お\s*(?:釣り?|つり)|釣\s*(?:り|銭)?|つり\s*銭/i.freeze
    ANALYSIS_SETTLEMENT_AMOUNT_CANDIDATE_PATTERN = /[▲△\-−]?\s*[¥￥]?\s*(?:\d{1,3}(?:[,，.]\d{3})+|\d+)(?:円)?/.freeze
    ANALYSIS_REDUCED_TAX_MARKER_PATTERN = /軽|軽減/.freeze
    ANALYSIS_FALLBACK_NON_ITEM_KEYWORD_PATTERN = /小計|消費税|税額|総合計|合計|支払|お支払い|預り|お預り|釣銭|お釣り/.freeze
    ANALYSIS_FALLBACK_REFERENCE_LINE_PATTERN = /TEL|ＴＥＬ|電話番号|電話|住所|所在地|登録番号|インボイス|T番号|適格請求書|事業者番号|伝票番号|取引番号|レシート番号/i.freeze
    ANALYSIS_FALLBACK_DATE_TIME_LINE_PATTERN = %r{\d{4}[\/-]\d{1,2}[\/-]\d{1,2}|\d{4}年\d{1,2}月\d{1,2}日|\d{1,2}[:：]\d{2}|日付|日時|時刻|期間|販売期間|有効期限}.freeze
    ANALYSIS_FALLBACK_AMOUNT_CANDIDATE_PATTERN = /[¥￥]?\s*-?(?:\d{1,3}(?:[,，]\d{3})+|\d{1,3}(?:\s+\d{3})+|\d+)(?:円)?/.freeze
    ANALYSIS_ADJUSTMENT_AMOUNT_CANDIDATE_PATTERN = /[▲△\-−]?\s*[¥￥]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d{1,3}(?:\s+\d{3})+|\d+)(?:円)?/.freeze
    ANALYSIS_POINT_ONLY_TEXT_PATTERN = /ポイント|point|(?<![A-Za-z0-9])\d+\s*p(?:t|ts|oint|oints)?(?![A-Za-z0-9])/i.freeze
    ANALYSIS_POINT_MONEY_CONTEXT_PATTERN = /[¥￥円]|[▲△\-−]|利用額|支払額|決済額|金額|amount|payment|paid/i.freeze
    ANALYSIS_POST_SETTLEMENT_PROMO_ADJUSTMENT_PATTERN = /円引き|値引|割引|クーポン|coupon|discount|off|キャンペーン|アプリ|次回|特典|プレゼント|get/i.freeze
    ANALYSIS_POST_SETTLEMENT_PROMO_CONTEXT_PATTERN = /アンケート|広告|キャンペーン|アプリ|次回|特典|プレゼント|get|回答期限|coupon|survey|promotion|campaign/i.freeze
    ANALYSIS_POST_SETTLEMENT_BOUNDARY_PATTERN = /合計|総合計|お支払|支払|決済|現金|現\s*計|クレジット|カード売上票|お客様控|レシート\s*no|receipt\s*no|payment|paid|total|カード番号|承認番号|取引番号/i.freeze
    ANALYSIS_NON_REPRESENTATIVE_PAYMENT_PATTERN = /ポイント|point|クーポン|coupon|商品券|ギフト(?:カード)?|gift(?:\s*certificate|\s*card)?|voucher|優待券|利用券/i.freeze
    SIGNAL_RECEIPT_AMOUNT_CONTEXT_PATTERN = /(領収書|領収証|レシート|receipt|合計|小計|消費税|税額|税込|税抜|支払|決済|お預かり|お預り|預かり|預り|お釣り|釣銭|つり銭)/i.freeze
    SIGNAL_RECEIPT_WORD_PATTERN = /領収書|領収証|レシート|receipt/i.freeze
    SIGNAL_NON_ITEM_CONTEXT_PATTERN = /合計|小計|消費税|税額|税込|税抜|支払|決済|お預かり|お預り|預かり|預り|お釣り|釣銭|つり銭/i.freeze
    SIGNAL_PHONE_PATTERN = /tel|電話|0\d{1,4}-\d{1,4}-\d{3,4}/i.freeze
    SIGNAL_ADDRESS_PATTERN = /〒|東京都|北海道|(?:京都|大阪)府|.{1,8}[県市区町村]|丁目|番地/.freeze
    SIGNAL_REGISTRATION_NUMBER_PATTERN = /登録番号|事業者番号|T\d{13}/i.freeze
    SIGNAL_HOUSEHOLD_BUDGET_KEYWORDS = %w[収入 支出 固定支出 変動支出 貯金 生活費 残金 家賃 サブスク 目標貯金].freeze
    SIGNAL_MARKETING_WEB_PAGE_PATTERNS = [
      %r{https?://}i,
      /www\./i,
      /\.(?:jp|com|net|org)(?:\/|\b)/i,
      /ホーム/,
      /メニュー/,
      /お知らせ/,
      /アクセス/,
      /ご予約/,
      /販売期間/,
      /all rights reserved/i,
      /copyright/i
    ].freeze
    SIGNAL_MENU_CONTEXT_PATTERNS = [
      /\bmenu\b/i,
      /メニュー/,
      /dinner/i,
      /lunch/i,
      /appetizer/i,
      /前菜/,
      /main/i,
      /メイン/,
      /set menu/i,
      /セットメニュー/,
      /dessert/i,
      /drink/i
    ].freeze
    SIGNAL_CATALOG_CONTEXT_PATTERNS = [
      /商品一覧/,
      /商品画像/,
      /商品名/,
      /商品コード/,
      /カテゴリー/,
      /特徴/,
      /希望小売価格/,
      /在庫状況/,
      /おすすめ/,
      /レビュー/,
      /送料無料/,
      /会員限定/,
      /ランキング/,
      /人気商品/,
      /商品説明/
    ].freeze
    SIGNAL_SOCIAL_CONTEXT_PATTERNS = [
      /x\.com/i,
      /@\w+/,
      /#\S+/,
      /ポスト/,
      /投稿/,
      /返信/,
      /コメント/,
      /シェア/,
      /フォロー/,
      /いいね/,
      /表示/,
      /grok/i
    ].freeze
    SIGNAL_FLYER_CONTEXT_PATTERNS = [
      /チラシ/,
      /広告/,
      /セール/,
      /キャンペーン/,
      /大特価/,
      /特価/,
      /週末限定/,
      /期間限定/,
      /お買い得/,
      /まとめ買い/,
      /セール開催/,
      /会員募集中/,
      /日替り特価/,
      /ご来店ください/,
      /ご用意しました/,
      /入会金/,
      /年会費/
    ].freeze
    SIGNAL_PDF_DOCUMENT_CONTEXT_PATTERNS = [
      /\.pdf/i,
      /\/users\//i,
      /操作マニュアル/,
      /マニュアル/,
      /第\d+(?:\.\d+)?版/,
      /はじめに/,
      /基本の流れ/,
      /画面の説明/,
      /本文/,
      /章/,
      /ページ/,
      /アップロード/,
      /ocr/i,
      /ai/i,
      /ファイル/
    ].freeze
    STORE_LEGAL_ENTITY_PATTERN = /
      株式会社|有限会社|合同会社|合名会社|合資会社|一般社団法人|一般財団法人|公益社団法人|公益財団法人|
      \b(?:inc\.?|incorporated|ltd\.?|limited|llc|gmbh|ag|bv|nv|plc|corp\.?|corporation|company)\b|
      \b(?:co\.?\s*,?\s*ltd\.?|pty\s+ltd|pvt\.?\s+ltd|s\.?\s*a\.?|s\.?\s*a\.?\s*s\.?)\b
    /ix.freeze
    STORE_OPERATOR_CONTEXT_PATTERN = /
      指定管理者|運営会社|管理会社|受託会社|委託先|管理者|運営者|登録事業者|適格請求書発行事業者|
      operated\s+by|managed\s+by|management\s+company|operator|licensee|franchisee|franchise\s+owner|
      contractor|concessionaire|tax[-\s]*registered|registered\s+(?:entity|business|merchant|company)|
      legal\s+entity|merchant\s+of\s+record|trading\s+as
    /ix.freeze
    STORE_HEADING_STOP_PATTERN = /
      領収書|領収証|レシート|receipt|登録番号|インボイス|適格請求書|tax\s*(?:id|number)|vat\s*(?:id|number)|
      tel|電話|fax|住所|所在地|合計|小計|消費税|税率|税額|税込|税抜|現計|支払|お支払|決済|点数|
      total|subtotal|tax|payment|cash|change
    /ix.freeze
    STORE_ADDRESS_LIKE_PATTERN = /
      [都道府県].*\d|[市区町村郡].*\d|〒|\d+[-丁目番地号]|
      \b(?:street|st\.|road|rd\.|avenue|ave\.|blvd\.|drive|dr\.|suite|floor)\b.*\d
    /ix.freeze
    STORE_DATE_TIME_PATTERN = /
      \d{4}[\/\-年]\s*\d{1,2}[\/\-月]\s*\d{1,2}日?|\d{1,2}[:：]\d{2}|\d{1,2}時\d{1,2}分
    /x.freeze
    STORE_DESCRIPTIVE_ONLY_HEADING_PATTERN = /
      \A(
        [\s&＆・\/\-]+|
        イタリアン|フレンチ|中華|和食|洋食|ワイン|カフェ|喫茶|レストラン|ダイニング|バー|グリル|
        restaurant|cafe|coffee|bar|grill|dining|wine|bistro|kitchen
      )+\z
    /ix.freeze
    STORE_MESSAGE_LINE_PATTERN = /
      営業時間|営業案内|年中無休|定休日|元旦を除く|毎日.*安い|この価格|品質.*価格|
      暮らし応援価格|地域一番店|お買得|お買い得|特売|セール|
      business\s+hours|opening\s+hours|store\s+hours|hours\s*[:：]|open\s+\d|open\s+daily|
      everyday\s+low\s+price|low\s+price|best\s+price|quality\s+and\s+price|
      promotion|campaign|special\s+offer
    /ix.freeze
    STORE_LEGAL_ENTITY_DESIGNATOR_ONLY_PATTERN = /
      \A(
        株式会社|有限会社|合同会社|合名会社|合資会社|一般社団法人|一般財団法人|公益社団法人|公益財団法人|
        inc\.?|incorporated|ltd\.?|limited|llc|gmbh|ag|bv|nv|plc|corp\.?|corporation|company|
        co\.?\s*,?\s*ltd\.?|pty\s+ltd|pvt\.?\s+ltd|s\.?\s*a\.?|s\.?\s*a\.?\s*s\.?
      )\z
    /ix.freeze
    STORE_LOCAL_COMPLETE_NAME_SUFFIX_PATTERN = /店|本店|支店|営業所|センター|マーケット|スーパー|ストア|ショップ|カフェ|レストラン|食堂|商店|薬局|ドラッグ|コンビニ|駐車場/.freeze
    STORE_JAPANESE_LEGAL_DESIGNATOR_PREFIX_PATTERN = /\A(?:株式会社|有限会社|合同会社|合名会社|合資会社|一般社団法人|一般財団法人|公益社団法人|公益財団法人)\s*/i.freeze
    STORE_JAPANESE_LEGAL_DESIGNATOR_SUFFIX_PATTERN = /\s*(?:株式会社|有限会社|合同会社|合名会社|合資会社|一般社団法人|一般財団法人|公益社団法人|公益財団法人)\z/i.freeze
    STORE_LOCATION_MARKER_PATTERN = /店|支店|本店|営業所|センター|モール|通り|駅前|南口|北口|東口|西口|\bdowntown\b|\bnorth\b|\bsouth\b|\beast\b|\bwest\b/i.freeze
    STORE_LEGAL_ENTITY_BRANCH_EXCLUSION_PATTERN = /株式会社|有限会社|合同会社/.freeze
    STORE_BRANCH_PHONE_SUFFIX_PATTERN = /\s*(?:tel|電話|phone)\s*[:：]?\s*[+\d][\d+\-ー−()（）\s]*.*\z/i.freeze
    STORE_BRAND_TYPE_PATTERN = /マーケット|スーパー|ストア|ショップ|カフェ|レストラン|食堂|商店|薬局|ドラッグ|コンビニ|market|mart|store|shop|cafe|restaurant/i.freeze
    STORE_BUILDING_OR_FLOOR_PATTERN = /ビル|building|floor|地下|地上|[bB]\s*\d+\s*[fF]\b|\d+\s*[fF]\b|\d+\s*階/.freeze
    STORE_LOCAL_BUSINESS_DESCRIPTOR_PATTERN = /ショコラ|チョコ|ブティック|カフェ|レストラン|ショップ|ストア|マーケット|食堂|ダイニング/.freeze
    STORE_CONTEXT_COMPACT_NOISE_PATTERN = /領収書|領収証|小計|合計|担当|レジ|取引No|取引no/i.freeze
    STORE_CONTEXT_NOISE_PATTERN = /登録番号|店no|加盟店名|卓no|テーブル|席|人数|お客様相談室|サポート|ヘルプデスク|コールセンター/i.freeze
    STORE_CONTEXT_ADDRESS_PATTERN = /[都道府県].*\d|[市区町村郡].*\d|〒|\d+[-丁目番地号]/.freeze
    STORE_CONTEXT_RECEIPT_NOISE_PATTERN = /tel|電話|fax|領収書|領収証|レシート|合計|小計|消費税|税率|税額|支払|決済|total|subtotal|tax|payment/i.freeze
    STORE_BRANCH_SUFFIX = "店"
    STORE_PREMIUM_OUTLET_SUFFIX = "プレミアムアウトレット店"

    ANALYSIS_EXTERNAL_TAX_DESCRIPTION_PATTERN = /外税|税別|税抜|消費税別|別途消費税|exclusive|sales\s*tax/i.freeze
    ANALYSIS_CASH_TOTAL_PAYMENT_PATTERN = /現計|cashtotal/i.freeze
    ANALYSIS_TAX_TOTAL_LINE_PATTERN = /消費税.*合計|税額.*合計|tax\s*total/i.freeze
    ANALYSIS_TAX_TARGET_MARKER_PATTERN = /対象/.freeze
    ANALYSIS_TAX_AMOUNT_DESCRIPTION_PATTERN = /消費税|税額|tax/i.freeze
    ANALYSIS_NEGATIVE_ADJUSTMENT_CONTEXT_PATTERN = /値引|割引|ディスカウント|discount|off|クーポン|coupon|ポイント|point|返品|返金|refund|return/i.freeze
    ANALYSIS_ITEM_DISCOUNT_LABEL_PATTERN = /割引|discount|off/i.freeze
    ANALYSIS_RECEIPT_LEVEL_ADJUSTMENT_LINE_PATTERN = /クーポン|ポイント|coupon|point/i.freeze
    ANALYSIS_PREVIOUS_SUBTOTAL_CONTEXT_PATTERN = /小計|合計|総合計|total|subtotal/i.freeze
    ANALYSIS_GENERIC_RETURN_REFUND_LABEL_PATTERN = /\A(?:返品|返金|返却|refund|return)\z/i.freeze
    ANALYSIS_RETURN_REFUND_KIND_PATTERN = /返品|返金|返却|refund|return/i.freeze
    ANALYSIS_COUPON_KIND_PATTERN = /クーポン|coupon/i.freeze
    ANALYSIS_POINT_USAGE_KIND_PATTERN = /ポイント利用|point\s*use|points?\s*redeemed/i.freeze
    ANALYSIS_RECEIPT_DISCOUNT_KIND_PATTERN = /値引|割引|ディスカウント|discount|off/i.freeze
    ANALYSIS_LATE_NIGHT_CHARGE_KIND_PATTERN = /深夜|late.?night|midnight|after.?hours/i.freeze
    ANALYSIS_SERVICE_CHARGE_KIND_PATTERN = /サービス料|service\s*charge/i.freeze
    ANALYSIS_DELIVERY_FEE_KIND_PATTERN = /配送料|送料|delivery|shipping/i.freeze
    ANALYSIS_BAG_FEE_KIND_PATTERN = /レジ袋|袋代|bag/i.freeze
    ANALYSIS_HANDLING_FEE_KIND_PATTERN = /手数料|handling|fee|charge/i.freeze
    ANALYSIS_CASHLESS_REWARD_ADJUSTMENT_PATTERN = /キャッシュレス|cashless|payment\s*discount/i.freeze
    ANALYSIS_TAX_RATE_HINT_PATTERN = /(?:税率|対象|税込|税抜|軽)?\s*(8|10)\s*%/.freeze
    ANALYSIS_NON_TAXABLE_TEXT_PATTERN = /非課税|非課稅|non.?tax|tax.?free/i.freeze
    ANALYSIS_FALLBACK_TAX_TARGET_NON_ITEM_PATTERN = /対象計|対象額|税率対象|内税|内消費税/.freeze
    ANALYSIS_FALLBACK_TAX_AMOUNT_LINE_PATTERN = /\A(?:税込み?|税抜き?)(?:金額|価格)?[¥￥]?\d[\d,，]*円?\z/.freeze
    AMOUNT_TAX_DETAIL_INTERMEDIATE_PATTERN = /小\s*計.*税抜|税抜.*小\s*計|課税小計|対象小計/i.freeze
    AMOUNT_TAX_DETAIL_GROSS_PATTERN = /対象|税込|内消費税|内税|included/i.freeze
    AMOUNT_TAX_DETAIL_NET_PATTERN = /外税|税別|税抜|別途消費税|net|exclusive|tax\s*exclusive/i.freeze
    AMOUNT_TAX_DETAIL_TAX_ONLY_PATTERN = /消費税等?$|消費税$|税額$|tax$/i.freeze
    AMOUNT_TAX_DETAIL_GROSS_DESCRIPTION_PATTERN = /対象|対象額/.freeze
    AI_PAYMENT_HINTS = [
      "現金",
      "クレジット",
      "商品券",
      "交通系IC",
      "電子マネー",
      "PayPay",
      "楽天ペイ",
      "d払い",
      "au PAY",
      "メルペイ"
    ].freeze
    AI_TAX_HINTS = [
      "対象",
      "税込",
      "税抜",
      "内税",
      "外税",
      "消費税",
      "軽減税率",
      "非課税"
    ].freeze
    AI_ADJUSTMENT_HINTS = [
      "値引",
      "割引",
      "クーポン",
      "ポイント利用",
      "返品",
      "返金",
      "キャッシュレス還元"
    ].freeze
    AI_REMOVABLE_NOISE_LINE_PATTERN = /小計|合計|税込|税抜|内税|外税|消費税|税率|値引|割引|預り|釣り|お釣り|数量|個数|単価|商品コード|商品番号|SKU/.freeze
    AI_STORE_CANDIDATE_REFERENCE_NOISE_PATTERN = /tel|電話|レジ|伝票|領収|日時|合計|小計/i.freeze
    AI_PURCHASE_CONTEXT_LINE_PATTERN = /購入|会計|発行|伝票|領収|オーダー|注文|日時|時刻/.freeze
    AI_PAYMENT_CONTEXT_LINE_PATTERN = /現金|現計|現金計|現金合計|クレジット|カード|売上票|電子マネー|Edy|WAON|iD|QUICPay|交通系|Suica|PASMO|ICOCA|PayPay|楽天ペイ|d払い|au PAY|メルペイ|支払|決済|支払区分/.freeze
    AI_TAX_CONTEXT_LINE_PATTERN = /税率|税額|内税|外税|消費税|軽減税率|標準税率|対象|\d+％|\d+%/.freeze
    AI_BRANCH_SINGLE_NOISE_PATTERN = /\A(?:領|収|証|合計|お預り|お預かり|預り|預かり|お釣り?|釣り?|釣銭)\z/.freeze
    AI_BRANCH_CARD_OR_POINT_PREFIX_PATTERN = /\A(?:t|T)?(?:会員番号|カード番号|ポイント)/.freeze
    AI_BRANCH_SUPPORT_NOISE_PATTERN = /お客様相談室|サポート|ヘルプデスク|コールセンター/.freeze
    AI_BRANCH_REGISTRATION_NOISE_PATTERN = /登録番号|電話|tel|レジ|伝票|売上票|領収書|領収証|店no|加盟店名|卓no|テーブル|席|取引番号|端末番号|カード番号/i.freeze
    AI_BRANCH_POLITE_STATEMENT_PATTERN = /ます[。.]?\z/.freeze
    AI_BRANCH_USAGE_DATE_PATTERN = /ご利用日|利用日/.freeze
    AI_BRANCH_ORDER_TIME_PATTERN = /オーダー|注文|時刻|日時/.freeze
    AI_BRANCH_POINT_NOISE_PATTERN = /ポイント|楽天ポイント|Tポイント|dポイント|Ponta|WAON POINT|nanacoポイント/i.freeze
    AI_BRANCH_DETAIL_NOISE_PATTERN = /明細|会員|カード|マネー|残高|貯まり|利用可能|ご確認|https?:|www\.|\.jp/i.freeze
    AI_BRANCH_LOCATION_MARKER_PATTERN = /店|通り|駅前|本町|中央|南|北|東|西/.freeze
    AI_ADDRESS_EXCLUSION_PATTERN = /電話|TEL|お客様相談室|サポート|ヘルプデスク|コールセンター/.freeze
    AI_ADDRESS_REGISTRATION_NOISE_PATTERN = /登録番号|店no|レジ|伝票|売上票/.freeze
    AI_ADDRESS_CANDIDATE_PATTERN = /[都道府県]|[市区町村郡].*\d|\d+[\-丁目番地号]/.freeze

    class << self
      def country_codes
        COUNTRY_CODES
      end

      def cash_label
        CASH_LABEL
      end

      def voucher_label
        VOUCHER_LABEL
      end

      def point_usage_label
        POINT_USAGE_LABEL
      end

      def tax_rate_target_label(rate)
        "#{rate}%対象"
      end

      def quantity_unit_aliases
        QUANTITY_UNIT_ALIASES
      end

      def normalize_quantity_unit(value, default: ReceiptQuantityUnit.default_code)
        ReceiptQuantityUnit.normalize(value, default: default, aliases: quantity_unit_aliases)
      end

      def fallback_payment_method_patterns
        FALLBACK_PAYMENT_METHOD_PATTERNS
      end

      def fallback_item_category_patterns
        FALLBACK_ITEM_CATEGORY_PATTERNS
      end

      def fallback_payment_method_exclusion_patterns
        FALLBACK_PAYMENT_METHOD_EXCLUSION_PATTERNS
      end

      def fallback_payment_method_support_only_patterns
        FALLBACK_PAYMENT_METHOD_SUPPORT_ONLY_PATTERNS
      end

      def fallback_payment_method_transaction_context_pattern
        FALLBACK_PAYMENT_METHOD_TRANSACTION_CONTEXT_PATTERN
      end

      def ocr_payment_method_pattern
        OCR_PAYMENT_METHOD_PATTERN
      end

      def ocr_point_keywords_pattern
        OCR_POINT_KEYWORDS_PATTERN
      end

      def ocr_payment_keywords_pattern
        OCR_PAYMENT_KEYWORDS_PATTERN
      end

      def ocr_payment_support_only_pattern
        OCR_PAYMENT_SUPPORT_ONLY_PATTERN
      end

      def ocr_payment_transaction_context_pattern
        OCR_PAYMENT_TRANSACTION_CONTEXT_PATTERN
      end

      def ocr_cash_total_pattern
        OCR_CASH_TOTAL_PATTERN
      end

      def ocr_voucher_payment_pattern
        OCR_VOUCHER_PAYMENT_PATTERN
      end

      def ocr_settlement_line_pattern
        OCR_SETTLEMENT_LINE_PATTERN
      end

      def ocr_adjustment_discount_label_pattern
        OCR_ADJUSTMENT_DISCOUNT_LABEL_PATTERN
      end

      def ocr_adjustment_surcharge_label_pattern
        OCR_ADJUSTMENT_SURCHARGE_LABEL_PATTERN
      end

      def ocr_adjustment_excluded_line_pattern
        OCR_ADJUSTMENT_EXCLUDED_LINE_PATTERN
      end

      def ocr_adjustment_zone_start_pattern
        OCR_ADJUSTMENT_ZONE_START_PATTERN
      end

      def ocr_adjustment_zone_end_pattern
        OCR_ADJUSTMENT_ZONE_END_PATTERN
      end

      def ocr_merchant_anchor_pattern
        OCR_MERCHANT_ANCHOR_PATTERN
      end

      def ocr_datetime_anchor_pattern
        OCR_DATETIME_ANCHOR_PATTERN
      end

      def ocr_subtotal_anchor_pattern
        OCR_SUBTOTAL_ANCHOR_PATTERN
      end

      def ocr_total_anchor_pattern
        OCR_TOTAL_ANCHOR_PATTERN
      end

      def ocr_tax_anchor_pattern
        OCR_TAX_ANCHOR_PATTERN
      end

      def ocr_payment_anchor_pattern
        OCR_PAYMENT_ANCHOR_PATTERN
      end

      def ocr_generic_tax_detail_description_pattern
        OCR_GENERIC_TAX_DETAIL_DESCRIPTION_PATTERN
      end

      def ocr_tax_target_marker_pattern
        OCR_TAX_TARGET_MARKER_PATTERN
      end

      def ocr_tax_amount_description_pattern
        OCR_TAX_AMOUNT_DESCRIPTION_PATTERN
      end

      def ocr_tax_context_label_pattern
        OCR_TAX_CONTEXT_LABEL_PATTERN
      end

      def ocr_tax_rate_target_line_pattern(rate_label)
        /#{Regexp.escape(rate_label)}\s*[%％].{0,8}対象/
      end

      def ocr_item_discount_keyword_pattern
        OCR_ITEM_DISCOUNT_KEYWORD_PATTERN
      end

      def ocr_total_amount_line_pattern
        OCR_TOTAL_AMOUNT_LINE_PATTERN
      end

      def ocr_subtotal_amount_line_pattern
        OCR_SUBTOTAL_AMOUNT_LINE_PATTERN
      end

      def ocr_card_slip_context_pattern
        OCR_CARD_SLIP_CONTEXT_PATTERN
      end

      def ocr_payment_result_context_pattern
        OCR_PAYMENT_RESULT_CONTEXT_PATTERN
      end

      def ocr_receipt_level_discount_line_pattern
        OCR_RECEIPT_LEVEL_DISCOUNT_LINE_PATTERN
      end

      def ocr_item_discount_line_pattern
        OCR_ITEM_DISCOUNT_LINE_PATTERN
      end

      def analysis_fallback_payment_line_pattern
        ANALYSIS_FALLBACK_PAYMENT_LINE_PATTERN
      end

      def analysis_fallback_payment_action_pattern
        ANALYSIS_FALLBACK_PAYMENT_ACTION_PATTERN
      end

      def analysis_fallback_payment_excluded_pattern
        ANALYSIS_FALLBACK_PAYMENT_EXCLUDED_PATTERN
      end

      def analysis_fallback_payment_support_only_pattern
        ANALYSIS_FALLBACK_PAYMENT_SUPPORT_ONLY_PATTERN
      end

      def analysis_fallback_payment_transaction_context_pattern
        ANALYSIS_FALLBACK_PAYMENT_TRANSACTION_CONTEXT_PATTERN
      end

      def analysis_fallback_payment_amount_label_pattern
        ANALYSIS_FALLBACK_PAYMENT_AMOUNT_LABEL_PATTERN
      end

      def analysis_fallback_payment_metadata_label_pattern
        ANALYSIS_FALLBACK_PAYMENT_METADATA_LABEL_PATTERN
      end

      def analysis_fallback_payment_amount_noise_pattern
        ANALYSIS_FALLBACK_PAYMENT_AMOUNT_NOISE_PATTERN
      end

      def analysis_fallback_payment_address_amount_noise_pattern
        ANALYSIS_FALLBACK_PAYMENT_ADDRESS_AMOUNT_NOISE_PATTERN
      end

      def analysis_voucher_payment_pattern
        ANALYSIS_VOUCHER_PAYMENT_PATTERN
      end

      def analysis_point_payment_line_pattern
        ANALYSIS_POINT_PAYMENT_LINE_PATTERN
      end

      def analysis_point_payment_strong_line_pattern
        ANALYSIS_POINT_PAYMENT_STRONG_LINE_PATTERN
      end

      def analysis_point_display_line_pattern
        ANALYSIS_POINT_DISPLAY_LINE_PATTERN
      end

      def analysis_payment_block_anchor_pattern
        ANALYSIS_PAYMENT_BLOCK_ANCHOR_PATTERN
      end

      def analysis_explicit_payment_money_pattern
        ANALYSIS_EXPLICIT_PAYMENT_MONEY_PATTERN
      end

      def analysis_cash_deposit_label_pattern
        ANALYSIS_CASH_DEPOSIT_LABEL_PATTERN
      end

      def analysis_cash_change_label_pattern
        ANALYSIS_CASH_CHANGE_LABEL_PATTERN
      end

      def analysis_settlement_amount_candidate_pattern
        ANALYSIS_SETTLEMENT_AMOUNT_CANDIDATE_PATTERN
      end

      def analysis_reduced_tax_marker_pattern
        ANALYSIS_REDUCED_TAX_MARKER_PATTERN
      end

      def analysis_fallback_non_item_keyword_pattern
        ANALYSIS_FALLBACK_NON_ITEM_KEYWORD_PATTERN
      end

      def analysis_fallback_reference_line_pattern
        ANALYSIS_FALLBACK_REFERENCE_LINE_PATTERN
      end

      def analysis_fallback_date_time_line_pattern
        ANALYSIS_FALLBACK_DATE_TIME_LINE_PATTERN
      end

      def analysis_fallback_amount_candidate_pattern
        ANALYSIS_FALLBACK_AMOUNT_CANDIDATE_PATTERN
      end

      def analysis_adjustment_amount_candidate_pattern
        ANALYSIS_ADJUSTMENT_AMOUNT_CANDIDATE_PATTERN
      end

      def analysis_point_only_text_pattern
        ANALYSIS_POINT_ONLY_TEXT_PATTERN
      end

      def analysis_point_money_context_pattern
        ANALYSIS_POINT_MONEY_CONTEXT_PATTERN
      end

      def analysis_post_settlement_promo_adjustment_pattern
        ANALYSIS_POST_SETTLEMENT_PROMO_ADJUSTMENT_PATTERN
      end

      def analysis_post_settlement_promo_context_pattern
        ANALYSIS_POST_SETTLEMENT_PROMO_CONTEXT_PATTERN
      end

      def analysis_post_settlement_boundary_pattern
        ANALYSIS_POST_SETTLEMENT_BOUNDARY_PATTERN
      end

      def analysis_non_representative_payment_pattern
        ANALYSIS_NON_REPRESENTATIVE_PAYMENT_PATTERN
      end

      def signal_receipt_amount_context_pattern
        SIGNAL_RECEIPT_AMOUNT_CONTEXT_PATTERN
      end

      def signal_receipt_word_pattern
        SIGNAL_RECEIPT_WORD_PATTERN
      end

      def signal_non_item_context_pattern
        SIGNAL_NON_ITEM_CONTEXT_PATTERN
      end

      def signal_phone_pattern
        SIGNAL_PHONE_PATTERN
      end

      def signal_address_pattern
        SIGNAL_ADDRESS_PATTERN
      end

      def signal_registration_number_pattern
        SIGNAL_REGISTRATION_NUMBER_PATTERN
      end

      def signal_household_budget_keywords
        SIGNAL_HOUSEHOLD_BUDGET_KEYWORDS
      end

      def signal_marketing_web_page_patterns
        SIGNAL_MARKETING_WEB_PAGE_PATTERNS
      end

      def signal_menu_context_patterns
        SIGNAL_MENU_CONTEXT_PATTERNS
      end

      def signal_catalog_context_patterns
        SIGNAL_CATALOG_CONTEXT_PATTERNS
      end

      def signal_social_context_patterns
        SIGNAL_SOCIAL_CONTEXT_PATTERNS
      end

      def signal_flyer_context_patterns
        SIGNAL_FLYER_CONTEXT_PATTERNS
      end

      def signal_pdf_document_context_patterns
        SIGNAL_PDF_DOCUMENT_CONTEXT_PATTERNS
      end

      def store_legal_entity_pattern
        STORE_LEGAL_ENTITY_PATTERN
      end

      def store_operator_context_pattern
        STORE_OPERATOR_CONTEXT_PATTERN
      end

      def store_heading_stop_pattern
        STORE_HEADING_STOP_PATTERN
      end

      def store_address_like_pattern
        STORE_ADDRESS_LIKE_PATTERN
      end

      def store_date_time_pattern
        STORE_DATE_TIME_PATTERN
      end

      def store_descriptive_only_heading_pattern
        STORE_DESCRIPTIVE_ONLY_HEADING_PATTERN
      end

      def store_message_line_pattern
        STORE_MESSAGE_LINE_PATTERN
      end

      def store_legal_entity_designator_only_pattern
        STORE_LEGAL_ENTITY_DESIGNATOR_ONLY_PATTERN
      end

      def store_local_complete_name_suffix_pattern
        STORE_LOCAL_COMPLETE_NAME_SUFFIX_PATTERN
      end

      def store_japanese_legal_designator_prefix_pattern
        STORE_JAPANESE_LEGAL_DESIGNATOR_PREFIX_PATTERN
      end

      def store_japanese_legal_designator_suffix_pattern
        STORE_JAPANESE_LEGAL_DESIGNATOR_SUFFIX_PATTERN
      end

      def store_location_marker_pattern
        STORE_LOCATION_MARKER_PATTERN
      end

      def store_legal_entity_branch_exclusion_pattern
        STORE_LEGAL_ENTITY_BRANCH_EXCLUSION_PATTERN
      end

      def store_branch_phone_suffix_pattern
        STORE_BRANCH_PHONE_SUFFIX_PATTERN
      end

      def store_brand_type_pattern
        STORE_BRAND_TYPE_PATTERN
      end

      def store_building_or_floor_pattern
        STORE_BUILDING_OR_FLOOR_PATTERN
      end

      def store_local_business_descriptor_pattern
        STORE_LOCAL_BUSINESS_DESCRIPTOR_PATTERN
      end

      def store_context_compact_noise_pattern
        STORE_CONTEXT_COMPACT_NOISE_PATTERN
      end

      def store_context_noise_pattern
        STORE_CONTEXT_NOISE_PATTERN
      end

      def store_context_address_pattern
        STORE_CONTEXT_ADDRESS_PATTERN
      end

      def store_context_receipt_noise_pattern
        STORE_CONTEXT_RECEIPT_NOISE_PATTERN
      end

      def store_branch_suffix
        STORE_BRANCH_SUFFIX
      end

      def store_premium_outlet_suffix
        STORE_PREMIUM_OUTLET_SUFFIX
      end

      def analysis_external_tax_description_pattern
        ANALYSIS_EXTERNAL_TAX_DESCRIPTION_PATTERN
      end

      def analysis_cash_total_payment_pattern
        ANALYSIS_CASH_TOTAL_PAYMENT_PATTERN
      end

      def analysis_tax_total_line_pattern
        ANALYSIS_TAX_TOTAL_LINE_PATTERN
      end

      def analysis_tax_target_marker_pattern
        ANALYSIS_TAX_TARGET_MARKER_PATTERN
      end

      def analysis_tax_amount_description_pattern
        ANALYSIS_TAX_AMOUNT_DESCRIPTION_PATTERN
      end

      def analysis_negative_adjustment_context_pattern
        ANALYSIS_NEGATIVE_ADJUSTMENT_CONTEXT_PATTERN
      end

      def analysis_item_discount_label_pattern
        ANALYSIS_ITEM_DISCOUNT_LABEL_PATTERN
      end

      def analysis_receipt_level_adjustment_line_pattern
        ANALYSIS_RECEIPT_LEVEL_ADJUSTMENT_LINE_PATTERN
      end

      def analysis_previous_subtotal_context_pattern
        ANALYSIS_PREVIOUS_SUBTOTAL_CONTEXT_PATTERN
      end

      def analysis_generic_return_refund_label_pattern
        ANALYSIS_GENERIC_RETURN_REFUND_LABEL_PATTERN
      end

      def analysis_return_refund_kind_pattern
        ANALYSIS_RETURN_REFUND_KIND_PATTERN
      end

      def analysis_coupon_kind_pattern
        ANALYSIS_COUPON_KIND_PATTERN
      end

      def analysis_point_usage_kind_pattern
        ANALYSIS_POINT_USAGE_KIND_PATTERN
      end

      def analysis_receipt_discount_kind_pattern
        ANALYSIS_RECEIPT_DISCOUNT_KIND_PATTERN
      end

      def analysis_late_night_charge_kind_pattern
        ANALYSIS_LATE_NIGHT_CHARGE_KIND_PATTERN
      end

      def analysis_service_charge_kind_pattern
        ANALYSIS_SERVICE_CHARGE_KIND_PATTERN
      end

      def analysis_delivery_fee_kind_pattern
        ANALYSIS_DELIVERY_FEE_KIND_PATTERN
      end

      def analysis_bag_fee_kind_pattern
        ANALYSIS_BAG_FEE_KIND_PATTERN
      end

      def analysis_handling_fee_kind_pattern
        ANALYSIS_HANDLING_FEE_KIND_PATTERN
      end

      def analysis_cashless_reward_adjustment_pattern
        ANALYSIS_CASHLESS_REWARD_ADJUSTMENT_PATTERN
      end

      def analysis_tax_rate_hint_pattern
        ANALYSIS_TAX_RATE_HINT_PATTERN
      end

      def analysis_non_taxable_text_pattern
        ANALYSIS_NON_TAXABLE_TEXT_PATTERN
      end

      def analysis_fallback_tax_target_non_item_pattern
        ANALYSIS_FALLBACK_TAX_TARGET_NON_ITEM_PATTERN
      end

      def analysis_fallback_tax_amount_line_pattern
        ANALYSIS_FALLBACK_TAX_AMOUNT_LINE_PATTERN
      end

      def amount_tax_detail_intermediate_pattern
        AMOUNT_TAX_DETAIL_INTERMEDIATE_PATTERN
      end

      def amount_tax_detail_gross_pattern
        AMOUNT_TAX_DETAIL_GROSS_PATTERN
      end

      def amount_tax_detail_net_pattern
        AMOUNT_TAX_DETAIL_NET_PATTERN
      end

      def amount_tax_detail_tax_only_pattern
        AMOUNT_TAX_DETAIL_TAX_ONLY_PATTERN
      end

      def amount_tax_detail_gross_description_pattern
        AMOUNT_TAX_DETAIL_GROSS_DESCRIPTION_PATTERN
      end

      def ai_profile_hints
        {
          payment_terms: AI_PAYMENT_HINTS,
          tax_terms: AI_TAX_HINTS,
          adjustment_terms: AI_ADJUSTMENT_HINTS
        }
      end

      def ai_removable_noise_line_pattern
        AI_REMOVABLE_NOISE_LINE_PATTERN
      end

      def ai_store_candidate_reference_noise_pattern
        AI_STORE_CANDIDATE_REFERENCE_NOISE_PATTERN
      end

      def ai_purchase_context_line_pattern
        AI_PURCHASE_CONTEXT_LINE_PATTERN
      end

      def ai_payment_context_line_pattern
        AI_PAYMENT_CONTEXT_LINE_PATTERN
      end

      def ai_tax_context_line_pattern
        AI_TAX_CONTEXT_LINE_PATTERN
      end

      def ai_branch_single_noise_pattern
        AI_BRANCH_SINGLE_NOISE_PATTERN
      end

      def ai_branch_card_or_point_prefix_pattern
        AI_BRANCH_CARD_OR_POINT_PREFIX_PATTERN
      end

      def ai_branch_support_noise_pattern
        AI_BRANCH_SUPPORT_NOISE_PATTERN
      end

      def ai_branch_registration_noise_pattern
        AI_BRANCH_REGISTRATION_NOISE_PATTERN
      end

      def ai_branch_polite_statement_pattern
        AI_BRANCH_POLITE_STATEMENT_PATTERN
      end

      def ai_branch_usage_date_pattern
        AI_BRANCH_USAGE_DATE_PATTERN
      end

      def ai_branch_order_time_pattern
        AI_BRANCH_ORDER_TIME_PATTERN
      end

      def ai_branch_point_noise_pattern
        AI_BRANCH_POINT_NOISE_PATTERN
      end

      def ai_branch_detail_noise_pattern
        AI_BRANCH_DETAIL_NOISE_PATTERN
      end

      def ai_branch_location_marker_pattern
        AI_BRANCH_LOCATION_MARKER_PATTERN
      end

      def ai_address_exclusion_pattern
        AI_ADDRESS_EXCLUSION_PATTERN
      end

      def ai_address_registration_noise_pattern
        AI_ADDRESS_REGISTRATION_NOISE_PATTERN
      end

      def ai_address_candidate_pattern
        AI_ADDRESS_CANDIDATE_PATTERN
      end
    end
  end
end
