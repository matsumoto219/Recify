module Analysis
  class ReceiptBuildParamsService
    TAX_RATE_CONFIDENCE_WARNING_THRESHOLD = BigDecimal("0.75")
    FALLBACK_PAYMENT_LINE_PATTERN = /現金|cash|visa|master|mastercard|jcb|amex|american express|suica|pasmo|icoca|waon|nanaco|edy|id|quickpay|quicpay|paypay|楽天ペイ|rakuten pay|d払い|au pay|メルペイ|line pay|デビット|debit/i
    FALLBACK_NON_ITEM_KEYWORD_PATTERN = /小計|消費税|税額|総合計|合計|支払|お支払い|預り|お預り|釣銭|お釣り/
    FALLBACK_REFERENCE_LINE_PATTERN = /TEL|ＴＥＬ|電話番号|電話|住所|所在地|登録番号|インボイス|T番号|適格請求書|事業者番号|伝票番号|取引番号|レシート番号/i
    FALLBACK_DATE_TIME_LINE_PATTERN = %r{\d{4}[\/-]\d{1,2}[\/-]\d{1,2}|\d{4}年\d{1,2}月\d{1,2}日|\d{1,2}[:：]\d{2}|日付|日時|時刻|期間|販売期間|有効期限}
    FALLBACK_URL_OR_EMAIL_PATTERN = %r{https?://|www\.|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}}i
    FALLBACK_AMOUNT_CANDIDATE_PATTERN = /[¥￥]?\s*-?(?:\d{1,3}(?:[,，]\d{3})+|\d{1,3}(?:\s+\d{3})+|\d+)(?:円)?/
    PAYMENT_METHOD_REPRESENTATIVE_PRIORITY = %w[credit_card cash e_money qr_payment debit_card].freeze
    NON_REPRESENTATIVE_PAYMENT_PATTERN = /ポイント|point|クーポン|coupon|商品券|ギフト(?:カード)?|gift(?:\s*certificate|\s*card)?|voucher|優待券|利用券/i

    class << self
      def call(ocr_result:, ai_result: nil)
        normalized_ocr_result = normalize_ocr_result(ocr_result)
        candidates = normalize_candidates(normalized_ocr_result)
        normalized_ai_result = normalize_ai_result(ai_result)
        receipt_attributes = build_receipt_attributes(candidates, normalized_ai_result[:receipt_attributes])
        receipt_items_attributes = build_receipt_items_attributes(candidates, normalized_lines(normalized_ocr_result), normalized_ai_result[:receipt_items_attributes])
        receipt_payments_attributes = build_receipt_payments_attributes(candidates)
        receipt_tax_details_attributes = build_receipt_tax_details_attributes(candidates)

        apply_single_tax_detail_rate_to_items(receipt_items_attributes, receipt_tax_details_attributes)

        {
          # OCR/AI内部形式 -> receipts 保存用attributes
          receipt_attributes: receipt_attributes,
          # OCR/AI内部形式 -> receipt_items 保存用attributes
          receipt_items_attributes: receipt_items_attributes,
          # NOTE: 現状は Payments[] 自体の取得率が低く、保存されても UI では未使用
          receipt_payments_attributes: receipt_payments_attributes,
          # NOTE: 税詳細は保存対象だが、現状は主に保持目的で UI では未使用
          receipt_tax_details_attributes: receipt_tax_details_attributes
        }
      end

      private

      def normalize_ocr_result(ocr_result)
        return {} unless ocr_result.is_a?(Hash)

        ocr_result.deep_symbolize_keys
      end

      def normalize_candidates(ocr_result)
        candidates = ocr_result[:candidates]
        return {} unless candidates.is_a?(Hash)

        candidates.deep_symbolize_keys
      end

      def normalized_lines(ocr_result)
        Array(ocr_result[:lines]).map(&:to_s)
      end

      def normalize_ai_result(ai_result)
        return { receipt_attributes: {}, receipt_items_attributes: [] } unless ai_result.is_a?(Hash)

        symbolized = ai_result.deep_symbolize_keys

        # NOTE:
        # 現在の AI item は保存用完全データではなく、index ベースの補完データを受ける前提。
        # 主に suggested_name / category / needs_review を OCR item にマージするための中間形式として扱う。

        {
          receipt_attributes: symbolized[:receipt_attributes] || {},
          receipt_items_attributes: Array(symbolized[:receipt_items_attributes])
        }
      end

      def build_receipt_attributes(candidates, ai_receipt_attributes)
        ai_attrs = normalize_receipt_attributes(ai_receipt_attributes)

        {
          store_name: ai_attrs[:store_name].presence || candidates[:store_name],
          store_address: ai_attrs[:store_address].presence || candidates[:store_address],           # NOTE: 保存はするが、実レシートで未取得が多く現状UI活用は限定的
          store_phone_number: ai_attrs[:store_phone_number].presence || candidates[:store_phone_number],
          purchased_at: ai_attrs[:purchased_at].presence || parse_purchased_at(ai_attrs[:purchased_at_text]) || parse_purchased_at(candidates[:purchased_at_text]),
          total_amount: ai_attrs[:total_amount] || normalize_amount(candidates[:total_amount]),
          subtotal_amount: ai_attrs[:subtotal_amount] || normalize_amount(candidates[:subtotal_amount]),
          tax_amount: ai_attrs[:tax_amount] || normalize_amount(candidates[:tax_amount]),
          tax_rate: ai_attrs[:tax_rate] || normalize_rate(candidates[:tax_rate]),
          tip_amount: ai_attrs[:tip_amount] || normalize_amount(candidates[:tip_amount]),           # NOTE: 日本レシートではほぼ未取得。保存はするが現状未使用に近い
          country_region: normalize_country_region(
            ai_attrs[:country_region].presence || candidates[:country_region]
          ), # NOTE: 保存優先項目。現状UIでは未使用
          receipt_type: ai_attrs[:receipt_type].presence || candidates[:receipt_type],              # NOTE: 保存優先項目。現状UIでは未使用
          payment_method: ai_attrs[:payment_method].presence || detect_payment_method(candidates),
          processing_error_code: ai_attrs[:processing_error_code],
          processing_error_message: ai_attrs[:processing_error_message],
          ocr_completed_at: ai_attrs[:ocr_completed_at]
        }.compact
      end

      def build_receipt_items_attributes(candidates, lines, ai_items)
        candidate_items = Array(candidates[:items])
        normalized_ai_items = normalize_items(ai_items)

        source_items = if candidate_items.present?
          if normalized_ai_items.present?
            merge_items(candidate_items, normalized_ai_items)
          else
            candidate_items
          end
        else
          fallback_items = build_items_from_lines(lines)

          if normalized_ai_items.present?
            merge_items(fallback_items, normalized_ai_items)
          else
            fallback_items
          end
        end

        ai_items_present = normalized_ai_items.present?
        # NOTE: product_code は保存のみ。quantity_unit は編集/表示で利用する。
        source_items.each_with_index.map do |item, index|
          normalized_item = if item.respond_to?(:with_indifferent_access)
            item.with_indifferent_access
          elsif item.respond_to?(:deep_symbolize_keys)
            item.deep_symbolize_keys.with_indifferent_access
          else
            {}.with_indifferent_access
          end

          raw_text = normalized_item[:raw_text].to_s
          quantity = normalize_quantity(normalized_item[:quantity])
          discount_amount = normalize_amount(normalized_item[:discount_amount])
          explicit_original_line_total = normalize_amount(normalized_item[:original_line_total])
          raw_line_total = normalize_amount(normalized_item[:line_total])
          fallback_line_total = raw_line_total || extract_item_line_total(raw_text, price: normalize_amount(normalized_item[:price]), quantity:)
          original_line_total = explicit_original_line_total || fallback_line_total
          line_total = effective_line_total(
            original_line_total: explicit_original_line_total,
            fallback_line_total: fallback_line_total,
            discount_amount: discount_amount
          )
          price = normalize_amount(normalized_item[:price]) || infer_unit_price(original_line_total:, line_total:, quantity:)
          raw_category = normalized_item[:category].presence
          category = normalize_category(raw_category)
          category_invalid = raw_category.present? && category.nil?
          tax_rate = normalize_rate(normalized_item[:tax_rate])
          tax_rate_confidence = normalize_tax_rate_confidence(normalized_item[:tax_rate_confidence])
          review_reasons = item_review_reasons(
            normalized_item,
            tax_rate_confidence:,
            category_invalid:
          )

          {
            # Azure Items[].Description / Name -> receipt_items.raw_text
            raw_text: raw_text,
            suggested_name: normalized_item[:suggested_name].presence || extract_item_name(raw_text),
            # NOTE: AI は confirmed_name を返さず、補完候補は suggested_name に保持する。
            confirmed_name: normalized_item[:confirmed_name],
            category: category_invalid ? nil : (category || detect_category(raw_text)),
            price: price,
            quantity: quantity,
            original_line_total: original_line_total,
            discount_amount: discount_amount,
            discount_rate: normalize_rate(normalized_item[:discount_rate]),
            # Azure Items[].QuantityUnit -> receipt_items.quantity_unit
            quantity_unit: normalized_item[:quantity_unit],
            # Azure Items[].ProductCode -> receipt_items.product_code
            product_code: normalized_item[:product_code],
            # Azure TaxDetails[].Rate / item補完値 -> receipt_items.tax_rate（0.08 / 0.1 形式）
            tax_rate: tax_rate,
            line_total: line_total,
            needs_review: final_item_needs_review(
              normalized_item,
              ai_items_present: ai_items_present,
              tax_rate: tax_rate,
              tax_rate_confidence: tax_rate_confidence,
              review_reasons: review_reasons,
              category_invalid: category_invalid
            ),
            review_reasons: review_reasons,
            position_index: normalized_item[:position_index] || normalized_item[:index] || index + 1,
            confidence: normalize_confidence(normalized_item[:confidence])
          }
        end
      end

      def build_receipt_payments_attributes(candidates)
        # NOTE: Payments[] が取れた場合のみ保存。現状は payment_method への fallback 利用が主で、receipt_payments 自体は未活用
        Array(candidates[:payments]).map do |payment|
          normalized_payment = payment.respond_to?(:deep_symbolize_keys) ? payment.deep_symbolize_keys : {}

          {
            # Azure Payments[].Method -> receipt_payments.method
            method: normalized_payment[:method],
            # Azure Payments[].Amount -> receipt_payments.amount
            amount: normalize_amount(normalized_payment[:amount])
          }.compact
        end
      end

      def build_receipt_tax_details_attributes(candidates)
        # NOTE: 税詳細は保存できる場合のみ保存。現状は tax_rate / tax_amount の補助情報で UI では未活用
        Array(candidates[:tax_details]).map do |tax_detail|
          normalized_tax_detail = tax_detail.respond_to?(:deep_symbolize_keys) ? tax_detail.deep_symbolize_keys : {}

          {
            # Azure TaxDetails[].Description -> receipt_tax_details.description
            description: normalized_tax_detail[:description],
            # Azure TaxDetails[].Amount -> receipt_tax_details.amount
            amount: normalize_amount(normalized_tax_detail[:amount]),
            # Azure TaxDetails[].Rate -> receipt_tax_details.rate
            rate: normalize_rate(normalized_tax_detail[:rate]),
            # Azure TaxDetails[].NetAmount -> receipt_tax_details.net_amount
            net_amount: normalize_amount(normalized_tax_detail[:net_amount])
          }.compact
        end
      end

      def apply_single_tax_detail_rate_to_items(items, tax_details)
        return unless items.present?
        return unless items.all? { |item| item[:tax_rate].nil? }

        rates = Array(tax_details).filter_map do |tax_detail|
          rate = normalize_rate(tax_detail[:rate])
          amount = normalize_amount(tax_detail[:amount]).to_i
          next unless rate&.positive?
          next unless amount.positive?

          rate
        end.uniq
        return unless rates.one?

        items.each { |item| item[:tax_rate] = rates.first }
      end

      def normalize_receipt_attributes(attributes)
        return {} unless attributes.is_a?(Hash)

        symbolized = attributes.deep_symbolize_keys

        {
          store_name: symbolized[:store_name],
          store_address: symbolized[:store_address],               # NOTE: AI側から来ても現状UI活用は限定的
          store_phone_number: symbolized[:store_phone_number],
          purchased_at: symbolized[:purchased_at],
          purchased_at_text: symbolized[:purchased_at_text],
          total_amount: normalize_amount(symbolized[:total_amount]),
          subtotal_amount: normalize_amount(symbolized[:subtotal_amount]),
          tax_amount: normalize_amount(symbolized[:tax_amount]),
          tax_rate: normalize_rate(symbolized[:tax_rate]),
          tip_amount: normalize_amount(symbolized[:tip_amount]),   # NOTE: AI側から来ても現状未使用に近い
          country_region: normalize_country_region(symbolized[:country_region]), # NOTE: AI側から来ても保存優先。現状UIでは未使用
          receipt_type: symbolized[:receipt_type],                 # NOTE: AI側から来ても保存優先。現状UIでは未使用
          payment_method: symbolized[:payment_method],
          processing_error_code: symbolized[:processing_error_code],
          processing_error_message: symbolized[:processing_error_message],
          ocr_completed_at: symbolized[:ocr_completed_at]
        }.compact
      end

      def normalize_items(items)
        Array(items).filter_map do |item|
          next unless item.is_a?(Hash) || item.respond_to?(:to_h)

          item_hash = item.is_a?(Hash) ? item : item.to_h
          item_hash.with_indifferent_access
        end
      end

      def normalize_country_region(value)
        value.to_s.strip.upcase.presence
      end

      def merge_items(candidate_items, ai_items)
        normalized_candidate_items = Array(candidate_items).map do |item|
          item_hash = item.respond_to?(:deep_symbolize_keys) ? item.deep_symbolize_keys : {}
          item_hash.with_indifferent_access
        end
        normalized_ai_items = normalize_items(ai_items)

        ai_items_by_index = normalized_ai_items.each_with_object({}) do |item, result|
          ai_index = normalize_item_index(
            item[:index] || item["index"] || item[:position_index] || item["position_index"]
          )
          next if ai_index.nil?

          result[ai_index] = item
          result[ai_index + 1] ||= item
        end

        normalized_candidate_items.each_with_index.map do |candidate_item, candidate_index|
          candidate_position = normalize_item_index(
            candidate_item[:position_index] || candidate_item["position_index"]
          )
          lookup_candidates = [ candidate_position, candidate_index, candidate_index + 1 ].compact.uniq
          ai_item = lookup_candidates.lazy.map { |idx| ai_items_by_index[idx] }.find(&:present?) || {}.with_indifferent_access
          merged_item = candidate_item.merge(ai_item.compact)

          # NOTE: quantity_unit / product_code はOCR優先で保持する。
          merged_item.merge(
            suggested_name: ai_item[:suggested_name].presence || candidate_item[:suggested_name],
            category: ai_item[:category].presence || candidate_item[:category],
            needs_review: ai_item.key?(:needs_review) ? ai_item[:needs_review] : nil,
            review_reasons: ai_item[:review_reasons].presence || candidate_item[:review_reasons],
            quantity_unit: ai_item[:quantity_unit].presence || candidate_item[:quantity_unit],
            product_code: ai_item[:product_code].presence || candidate_item[:product_code],
            tax_rate: ai_item[:tax_rate].presence || candidate_item[:tax_rate],
            tax_rate_confidence: ai_item[:tax_rate_confidence],
            tax_rate_reason: ai_item[:tax_rate_reason],
            original_line_total: candidate_item[:original_line_total],
            discount_amount: candidate_item[:discount_amount],
            discount_rate: candidate_item[:discount_rate],
            position_index: candidate_position || candidate_index
          )
        end
      end

      def final_item_needs_review(normalized_item, ai_items_present:, tax_rate:, tax_rate_confidence:, review_reasons:, category_invalid:)
        return true if category_invalid
        return true if tax_rate.blank? && tax_rate_confidence_low?(tax_rate_confidence)

        if tax_rate.present? && tax_rate_confidence_low?(tax_rate_confidence)
          remaining_reasons = Array(review_reasons) - [ "item_tax_rate_uncertain" ]
          return false if remaining_reasons.empty?
        end

        if normalized_item.key?(:needs_review)
          normalized_item[:needs_review]
        else
          ai_items_present ? false : true
        end
      end

      def item_review_reasons(normalized_item, tax_rate_confidence:, category_invalid: false)
        normalize_review_reasons(normalized_item[:review_reasons]).tap do |reasons|
          reasons << "item_category_uncertain" if category_invalid
          reasons << "item_tax_rate_uncertain" if tax_rate_confidence_low?(tax_rate_confidence)
          reasons.uniq!
        end
      end

      def normalize_review_reasons(value)
        Array(value).filter_map do |reason|
          normalized = reason.to_s.strip
          normalized.presence
        end.uniq
      end

      def normalize_item_index(value)
        return nil if value.blank?
        return value.to_i if value.is_a?(Numeric)

        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end

      def effective_line_total(original_line_total:, fallback_line_total:, discount_amount:)
        discount_amount = discount_amount.to_i
        if original_line_total.present?
          return [ original_line_total - discount_amount, 0 ].max
        end

        fallback_line_total
      end

      def infer_unit_price(original_line_total:, line_total:, quantity:)
        total = original_line_total || line_total
        return nil unless total

        normalized_quantity = normalize_quantity(quantity)
        return total if normalized_quantity == BigDecimal("1")

        unit_price = BigDecimal(total.to_s) / normalized_quantity
        integer_unit_price = unit_price.to_i
        BigDecimal(integer_unit_price.to_s) == unit_price ? integer_unit_price : nil
      end

      def build_items_from_lines(lines)
        # NOTE: OCR Items[] が取れない場合の最終fallback。現状は review_needed 前提
        Array(lines).select { |line| item_line?(line) }.each_with_index.map do |line, index|
          price = extract_item_price(line)
          quantity = extract_item_quantity(line)

          {
            raw_text: line,
            suggested_name: extract_item_name(line),
            confirmed_name: nil,
            category: detect_category(line),
            price: price,
            quantity: quantity,
            quantity_unit: nil,
            product_code: nil,
            tax_rate: nil,
            original_line_total: extract_item_line_total(line, price:, quantity:),
            discount_amount: nil,
            discount_rate: nil,
            line_total: extract_item_line_total(line, price:, quantity:),
            needs_review: true,
            review_reasons: [ "item_name_uncertain" ],
            position_index: index,
            confidence: BigDecimal("0.3")
          }
        end
      end

      def item_line?(line)
        text = line.to_s.strip
        return false if text.blank?
        return false if fallback_non_item_line?(text)
        return false if extract_item_price(text).blank?

        extract_item_name(text).present?
      end

      def extract_item_price(line)
        amount_text = rightmost_fallback_amount_candidate(line)
        return nil if amount_text.blank?

        Amounts::NumberParser.parse_amount_or_nil(amount_text)
      end

      def fallback_non_item_line?(line)
        text = line.to_s.strip
        compact_text = text.gsub(/\s+/, "").delete(":：")

        return true if compact_text.match?(FALLBACK_NON_ITEM_KEYWORD_PATTERN)
        return true if compact_text.match?(/\A(?:税込み?|税抜き?)(?:金額|価格)?[¥￥]?\d[\d,，]*円?\z/)
        return true if text.match?(FALLBACK_REFERENCE_LINE_PATTERN)
        return true if text.match?(/\bT\d{13}\b/i)
        return true if text.match?(FALLBACK_DATE_TIME_LINE_PATTERN)
        return true if text.match?(FALLBACK_URL_OR_EMAIL_PATTERN)
        return true if text.match?(FALLBACK_PAYMENT_LINE_PATTERN)

        false
      end

      def fallback_amount_source(line)
        line.to_s.sub(/\s*[x×]\s*\d+(?:\.\d+)?\s*\z/i, "")
      end

      def rightmost_fallback_amount_candidate(line)
        source = fallback_amount_source(line)
        matches = source.to_enum(:scan, FALLBACK_AMOUNT_CANDIDATE_PATTERN).map { Regexp.last_match }
        return nil if matches.empty?

        matches.max_by { |match| match.end(0) }.to_s
      end

      def extract_item_quantity(line)
        quantity_match = line.to_s.match(/[x×]\s*(\d+(?:\.\d+)?)/i)
        return BigDecimal(quantity_match[1]) if quantity_match

        BigDecimal("1")
      end

      def detect_payment_method(candidates)
        # NOTE: OCR fieldの payment_method_text は支払い文脈が強い場合に優先し、
        # Payments[].Method はAI失敗 / OCR-only時の次点fallbackとして使う。
        detected_from_text = normalize_detected_payment_method(
          Analysis::ReceiptFallbackPatterns.detect_payment_method(candidates[:payment_method_text])
        )
        return detected_from_text if detected_from_text.present?

        detect_payment_method_from_payments(candidates[:payments])
      end

      def detect_payment_method_from_payments(payments)
        detected_methods = Array(payments).filter_map do |payment|
          normalized_payment = payment.respond_to?(:deep_symbolize_keys) ? payment.deep_symbolize_keys : {}
          method_text = normalized_payment[:method]
          next if method_text.blank?
          next if method_text.match?(NON_REPRESENTATIVE_PAYMENT_PATTERN)

          detected = Analysis::ReceiptFallbackPatterns.detect_payment_method(method_text)
          normalize_detected_payment_method(detected)
        end

        PAYMENT_METHOD_REPRESENTATIVE_PRIORITY.find { |method| detected_methods.include?(method) }
      end

      def normalize_detected_payment_method(detected_method)
        detected_method == "other" ? nil : detected_method.presence
      end

      def detect_category(text)
        # NOTE: 最終カテゴリ精度はAI担当。ここは OCR only / AI失敗時の簡易fallback
        Analysis::ReceiptFallbackPatterns.detect_category(text)
      end

      def parse_purchased_at(value)
        return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
        return nil if value.blank?

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def normalize_amount(value)
        Amounts::NumberParser.parse_amount_or_nil(value)
      end

      def normalize_rate(value)
        return nil if value.blank?

        rate = value.is_a?(Numeric) ? value.to_d : value.to_s.delete("%").to_d
        rate > 1 ? rate / 100 : rate
      rescue ArgumentError
        nil
      end

      def normalize_category(value)
        category = value.to_s.strip
        return nil if category.blank?

        ReceiptItem::CATEGORIES.include?(category) ? category : nil
      end

      def normalize_quantity(value)
        quantity = Amounts::NumberParser.parse_quantity(value, default: BigDecimal("1"))

        quantity.positive? ? quantity : BigDecimal("1")
      end

      def normalize_confidence(value)
        return nil if value.blank?

        BigDecimal(value.to_s)
      rescue ArgumentError
        nil
      end

      def normalize_tax_rate_confidence(value)
        confidence = normalize_confidence(value)
        return nil if confidence.nil?
        return nil if confidence.negative? || confidence > 1

        confidence
      end

      def tax_rate_confidence_low?(confidence)
        confidence.present? && confidence < TAX_RATE_CONFIDENCE_WARNING_THRESHOLD
      end

      def extract_item_name(line)
        source = fallback_amount_source(line)
        amount_text = rightmost_fallback_amount_candidate(line)
        return source.to_s.sub(/\s+\d.*$/, "").strip if amount_text.blank?

        amount_index = source.rindex(amount_text)
        name = amount_index ? source[0...amount_index] : source
        name.to_s.sub(/[¥￥]\s*\z/, "").strip
      end

      def extract_item_line_total(_line, price:, quantity:)
        return nil unless price

        (BigDecimal(price.to_s) * normalize_quantity(quantity)).round(0).to_i
      end
    end
  end
end
