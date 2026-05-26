module Analysis
  class ReceiptSignalEvaluator
    PASSING_SCORE = 5

    Result = Struct.new(:text_present, :score, :reasons, :strong_signal, :non_receipt_context, keyword_init: true) do
      def receipt_like?
        return false if non_receipt_context

        strong_signal || score >= PASSING_SCORE
      end
    end

    class << self
      def call(ocr_result)
        new(ocr_result).call
      end
    end

    def initialize(ocr_result)
      @ocr_result = ocr_result || {}
    end

    def call
      Result.new(
        text_present: text_present?,
        score: score,
        reasons: reasons,
        strong_signal: strong_signal?,
        non_receipt_context: non_receipt_context?
      )
    end

    private

    attr_reader :ocr_result

    def score
      @score ||= begin
        value = 0
        value += total_amount_score
        value += valid_items_score
        value += 3 if tax_details?
        value += 2 if payments?
        value += 3 if receipt_amount_context_line?
        value += 2 if receipt_word?
        value += money_like_item_lines_score
        value += 1 if purchased_at_signal?
        value += 1 if payment_method_text?
        value += supplemental_business_signal_score
        value += 1 if receipt_doc_type?
        value
      end
    end

    def reasons
      @reasons ||= begin
        values = []
        values << :total_amount if positive_total_amount?
        values << :valid_items if valid_items?
        values << :tax_details if tax_details?
        values << :payments if payments?
        values << :receipt_amount_context_line if receipt_amount_context_line?
        values << :receipt_word if receipt_word?
        values << :money_like_item_lines if money_like_item_lines_count.positive?
        values << :purchased_at if candidates[:purchased_at_text].present?
        values << :date_time_pattern if date_time_pattern?
        values << :payment_method_text if payment_method_text?
        values << :phone_number if phone_number_signal?
        values << :address if address_signal?
        values << :registration_number if registration_number_signal?
        values << :doc_type_receipt if receipt_doc_type?
        values << :non_receipt_context if non_receipt_context?
        values.uniq
      end
    end

    def strong_signal?
      return false if non_receipt_context?

      total_amount_receipt_context? ||
        valid_items_receipt_context? ||
        (receipt_word? && receipt_amount_context_line?) ||
        dated_money_like_item_lines?
    end

    def text_present?
      text_lines.present? ||
        ocr_result[:raw_text].to_s.strip.present? ||
        ocr_result[:content].to_s.strip.present?
    end

    def positive_total_amount?
      amount = parse_amount(candidates[:total_amount])

      amount.present? && amount.positive?
    end

    def total_amount_score
      return 0 unless positive_total_amount?

      total_amount_receipt_context? ? 5 : 2
    end

    def total_amount_receipt_context?
      positive_total_amount? &&
        (
          receipt_amount_context_line? ||
          receipt_word? ||
          payments? ||
          payment_method_text? ||
          tax_details?
        )
    end

    def valid_items?
      valid_items.any?
    end

    def valid_items_score
      return 0 unless valid_items?

      valid_items_receipt_context? ? 5 : [ valid_items.size, 3 ].min
    end

    def valid_items_receipt_context?
      valid_items? &&
        (
          total_amount_receipt_context? ||
          receipt_word? ||
          tax_details? ||
          payments? ||
          payment_method_text? ||
          receipt_amount_context_line?
        )
    end

    def valid_items
      @valid_items ||= Array(candidates[:items]).select do |item|
        symbolized = item.respond_to?(:deep_symbolize_keys) ? item.deep_symbolize_keys : {}
        symbolized[:raw_text].to_s.strip.present? &&
          %i[line_total price original_line_total].any? { |key| symbolized.key?(key) && symbolized[key].present? }
      end
    end

    def tax_details?
      Array(candidates[:tax_details]).present?
    end

    def payments?
      Array(candidates[:payments]).present?
    end

    def receipt_amount_context_line?
      text_lines.any? do |line|
        line.match?(/(領収書|領収証|レシート|receipt|合計|小計|消費税|税額|税込|税抜|支払|決済|お預かり|お預り|預かり|預り|お釣り|釣銭|つり銭)/i) &&
          amount_like_text?(line)
      end
    end

    def receipt_word?
      text_lines.any? { |line| line.match?(/領収書|領収証|レシート|receipt/i) }
    end

    def money_like_item_lines_score
      [ money_like_item_lines_count, 3 ].min
    end

    def money_like_item_lines_count
      @money_like_item_lines_count ||= text_lines.count { |line| money_like_item_line?(line) }
    end

    def money_like_item_line?(line)
      normalized = line.to_s
      return false if normalized.match?(/合計|小計|消費税|税額|税込|税抜|支払|決済|お預かり|お預り|預かり|預り|お釣り|釣銭|つり銭/i)
      return false unless normalized.match?(/[一-龠ぁ-んァ-ヶA-Za-z]/)

      amount_like_text?(normalized)
    end

    def amount_like_text?(text)
      normalized = text.to_s
      return true if normalized.match?(/[¥￥]\s*\d/)
      return true if normalized.match?(/\d[\d,]*\s*円/)
      return false if normalized.match?(/\d{4}[\/\-年]\d{1,2}[\/\-月]\d{1,2}日?/)

      normalized.match?(/(?:^|[[:space:]])\d[\d,]*(?:$|[[:space:]])/)
    end

    def purchased_at_signal?
      candidates[:purchased_at_text].present? || date_time_pattern?
    end

    def date_time_pattern?
      text_lines.any? do |line|
        line.match?(/\d{4}[\/\-年]\d{1,2}[\/\-月]\d{1,2}日?(\s+\d{1,2}:\d{2})?/) ||
          line.match?(/\d{1,2}[\/\-]\d{1,2}[\/\-]\d{1,2,4}(\s+\d{1,2}:\d{2})?/) ||
          line.match?(/\d{1,2}:\d{2}/)
      end
    end

    def payment_method_text?
      candidates[:payment_method_text].present?
    end

    def supplemental_business_signal_score
      [
        phone_number_signal?,
        address_signal?,
        registration_number_signal?
      ].count(true).clamp(0, 2)
    end

    def phone_number_signal?
      candidates[:store_phone_number].present? ||
        text_lines.any? { |line| line.match?(/tel|電話|0\d{1,4}-\d{1,4}-\d{3,4}/i) }
    end

    def address_signal?
      candidates[:store_address].present? ||
        text_lines.any? { |line| line.match?(/〒|東京都|北海道|(?:京都|大阪)府|.{1,8}[県市区町村]|丁目|番地/) }
    end

    def registration_number_signal?
      text_lines.any? { |line| line.match?(/登録番号|事業者番号|T\d{13}/i) }
    end

    def receipt_doc_type?
      meta[:doc_type].to_s.match?(/\Areceipt\./i)
    end

    def dated_money_like_item_lines?
      money_like_item_lines_count >= 2 && purchased_at_signal?
    end

    def non_receipt_context?
      household_budget_context? ||
        marketing_web_page_context? ||
        menu_or_catalog_context? ||
        social_post_context? ||
        flyer_context? ||
        pdf_document_context?
    end

    def household_budget_context?
      return false if receipt_word?

      keywords = %w[収入 支出 固定支出 変動支出 貯金 生活費 残金 家賃 サブスク 目標貯金]
      normalized_text = text_lines.join("\n")

      keywords.count { |keyword| normalized_text.include?(keyword) } >= 4
    end

    def marketing_web_page_context?
      return false if receipt_word? || payments? || payment_method_text? || tax_details?

      patterns = [
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
      ]
      normalized_text = text_lines.join("\n")

      patterns.count { |pattern| normalized_text.match?(pattern) } >= 3
    end

    def menu_or_catalog_context?
      return false if receipt_word? || tax_details? || payments?

      menu_context_score >= 3 || catalog_context_score >= 4
    end

    def social_post_context?
      return false if receipt_word? || tax_details? || payments?

      social_context_score >= 4
    end

    def flyer_context?
      return false if receipt_word? || tax_details? || payments? || payment_method_text?

      flyer_context_score >= 5
    end

    def pdf_document_context?
      return false if tax_details? || payments? || payment_method_text?

      pdf_document_context_score >= 4
    end

    def menu_context_score
      patterns = [
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
      ]
      normalized_text = text_lines.join("\n")

      patterns.count { |pattern| normalized_text.match?(pattern) }
    end

    def catalog_context_score
      patterns = [
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
      ]
      normalized_text = text_lines.join("\n")

      patterns.count { |pattern| normalized_text.match?(pattern) }
    end

    def social_context_score
      patterns = [
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
      ]
      normalized_text = text_lines.join("\n")

      patterns.count { |pattern| normalized_text.match?(pattern) }
    end

    def flyer_context_score
      patterns = [
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
      ]
      normalized_text = text_lines.join("\n")

      patterns.count { |pattern| normalized_text.match?(pattern) }
    end

    def pdf_document_context_score
      patterns = [
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
      ]
      normalized_text = text_lines.join("\n")

      patterns.count { |pattern| normalized_text.match?(pattern) }
    end

    def text_lines
      @text_lines ||= begin
        lines = Array(ocr_result[:lines]).map { |line| line.to_s.strip }.reject(&:blank?)
        if lines.present?
          lines
        else
          [ ocr_result[:content], ocr_result[:raw_text] ].flat_map do |text|
            text.to_s.lines.map(&:strip)
          end.reject(&:blank?)
        end
      end
    end

    def candidates
      @candidates ||= (ocr_result[:candidates] || {}).deep_symbolize_keys
    end

    def meta
      @meta ||= (ocr_result[:meta] || {}).deep_symbolize_keys
    end

    def parse_amount(value)
      ReceiptAmountService.parse_amount_or_nil(value)
    end
  end
end
