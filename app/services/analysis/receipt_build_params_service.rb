module Analysis
  class ReceiptBuildParamsService
    TAX_RATE_CONFIDENCE_WARNING_THRESHOLD = BigDecimal("0.75")
    FALLBACK_PAYMENT_LINE_PATTERN = /現金|cash|visa|master|mastercard|jcb|amex|american express|suica|pasmo|icoca|waon|nanaco|edy|id|quickpay|quicpay|paypay|楽天ペイ|rakuten pay|d払い|au pay|メルペイ|line pay|デビット|debit/i
    FALLBACK_NON_ITEM_KEYWORD_PATTERN = /小計|消費税|税額|総合計|合計|支払|お支払い|預り|お預り|釣銭|お釣り/
    FALLBACK_REFERENCE_LINE_PATTERN = /TEL|ＴＥＬ|電話番号|電話|住所|所在地|登録番号|インボイス|T番号|適格請求書|事業者番号|伝票番号|取引番号|レシート番号/i
    FALLBACK_DATE_TIME_LINE_PATTERN = %r{\d{4}[\/-]\d{1,2}[\/-]\d{1,2}|\d{4}年\d{1,2}月\d{1,2}日|\d{1,2}[:：]\d{2}|日付|日時|時刻|期間|販売期間|有効期限}
    FALLBACK_URL_OR_EMAIL_PATTERN = %r{https?://|www\.|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}}i
    FALLBACK_AMOUNT_CANDIDATE_PATTERN = /[¥￥]?\s*-?(?:\d{1,3}(?:[,，]\d{3})+|\d{1,3}(?:\s+\d{3})+|\d+)(?:円)?/
    ADJUSTMENT_AMOUNT_CANDIDATE_PATTERN = /[▲△\-−]?\s*[¥￥]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d{1,3}(?:\s+\d{3})+|\d+)(?:円)?/
    OCR_ADJUSTMENT_FALLBACK_CONFIDENCE_THRESHOLD = BigDecimal("0.75")
    PAYMENT_METHOD_REPRESENTATIVE_PRIORITY = %w[credit_card cash e_money qr_payment debit_card].freeze
    NON_REPRESENTATIVE_PAYMENT_PATTERN = /ポイント|point|クーポン|coupon|商品券|ギフト(?:カード)?|gift(?:\s*certificate|\s*card)?|voucher|優待券|利用券/i
    ADJUSTMENT_UNCERTAIN_REVIEW_REASON = "adjustment_uncertain"

    class << self
      def call(ocr_result:, ai_result: nil)
        normalized_ocr_result = normalize_ocr_result(ocr_result)
        candidates = normalize_candidates(normalized_ocr_result)
        lines = normalized_lines(normalized_ocr_result)
        normalized_ai_result = normalize_ai_result(ai_result)
        skipped_negative_items = []
        ai_receipt_attributes = normalized_ai_result[:receipt_attributes]
        receipt_attributes = build_receipt_attributes(candidates, ai_receipt_attributes, lines)
        receipt_items_attributes = build_receipt_items_attributes(
          candidates,
          lines,
          normalized_ai_result[:receipt_items_attributes],
          skipped_negative_items:
        )
        receipt_payments_attributes = build_receipt_payments_attributes(candidates)
        receipt_tax_details_attributes = build_receipt_tax_details_attributes(candidates)
        receipt_adjustments_attributes = build_receipt_adjustments_attributes(
          normalized_ai_result[:receipt_adjustments_attributes],
          candidates[:adjustment_candidates],
          lines
        )
        review_reasons = skipped_negative_adjustment_review_reasons(skipped_negative_items, receipt_adjustments_attributes)

        tax_rate_correction = apply_tax_detail_amount_match_policy(
          receipt_items_attributes,
          receipt_adjustments_attributes,
          receipt_tax_details_attributes
        ) || apply_single_tax_detail_rate_policy(
          receipt_items_attributes,
          receipt_adjustments_attributes,
          receipt_tax_details_attributes,
          receipt_attributes
        )
        corrections = build_params_corrections(
          purchased_at_fallback: purchased_at_fallback_snapshot(ai_receipt_attributes, candidates, lines),
          tax_rate_correction: tax_rate_correction
        )

        {
          # OCR/AI内部形式 -> receipts 保存用attributes
          receipt_attributes: receipt_attributes,
          # OCR/AI内部形式 -> receipt_items 保存用attributes
          receipt_items_attributes: receipt_items_attributes,
          # NOTE: 現状は Payments[] 自体の取得率が低く、保存されても UI では未使用
          receipt_payments_attributes: receipt_payments_attributes,
          # 税詳細は保存し、金額計算/サマリー表示の補助情報として利用する
          receipt_tax_details_attributes: receipt_tax_details_attributes,
          receipt_adjustments_attributes: receipt_adjustments_attributes,
          review_reasons: review_reasons,
          tax_rate_correction: tax_rate_correction,
          corrections: corrections
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
        return { receipt_attributes: {}, receipt_items_attributes: [], receipt_adjustments_attributes: [] } unless ai_result.is_a?(Hash)

        symbolized = ai_result.deep_symbolize_keys

        # AI item は保存用完全データではなく、index ベースの補完データを受ける前提。
        # 主に suggested_name / category / needs_review を OCR item にマージするための中間形式として扱う。

        {
          receipt_attributes: symbolized[:receipt_attributes] || {},
          receipt_items_attributes: Array(symbolized[:receipt_items_attributes]),
          receipt_adjustments_attributes: Array(symbolized[:receipt_adjustments_attributes])
        }
      end

      def build_receipt_attributes(candidates, ai_receipt_attributes, lines)
        ai_attrs = normalize_receipt_attributes(ai_receipt_attributes)

        {
          store_name: ai_attrs[:store_name].presence || candidates[:store_name],
          store_address: ai_attrs[:store_address].presence || candidates[:store_address],           # 実レシートでは未取得が多いが、取得値は住所として表示/編集対象にする
          store_address_components: normalize_store_address_components(
            ai_attrs[:store_address_components].presence || candidates[:store_address_components]
          ),
          store_phone_number: ai_attrs[:store_phone_number].presence || candidates[:store_phone_number],
          purchased_at: parse_purchased_at_with_time_fallback(ai_attrs, candidates, lines),
          total_amount: ai_attrs[:total_amount] || normalize_amount(candidates[:total_amount]),
          subtotal_amount: ai_attrs[:subtotal_amount] || normalize_amount(candidates[:subtotal_amount]),
          tax_amount: ai_attrs[:tax_amount] || normalize_amount(candidates[:tax_amount]),
          tax_rate: ai_attrs[:tax_rate] || normalize_rate(candidates[:tax_rate]),
          tip_amount: ai_attrs[:tip_amount] || normalize_amount(candidates[:tip_amount]),           # NOTE: 日本レシートではほぼ未取得。保存はするが現状未使用に近い
          currency_code: normalize_currency_code(ai_attrs[:currency_code].presence || candidates[:currency_code]),
          country_region: normalize_country_region(
            ai_attrs[:country_region].presence || candidates[:country_region]
          ), # 国判定/AI promptの補助に使う。UIでは表示しない
          receipt_type: ai_attrs[:receipt_type].presence || candidates[:receipt_type],              # NOTE: 保存優先項目。現状UIでは未使用
          payment_method: ai_attrs[:payment_method].presence || detect_payment_method(candidates),
          processing_error_code: ai_attrs[:processing_error_code],
          processing_error_message: ai_attrs[:processing_error_message],
          ocr_completed_at: ai_attrs[:ocr_completed_at]
        }.compact
      end

      def build_receipt_items_attributes(candidates, lines, ai_items, skipped_negative_items: [])
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
        # product_code は保存のみ。quantity_unit は編集/表示で利用する。
        source_items.each_with_index.filter_map do |item, index|
          normalized_item = if item.respond_to?(:with_indifferent_access)
            item.with_indifferent_access
          elsif item.respond_to?(:deep_symbolize_keys)
            item.deep_symbolize_keys.with_indifferent_access
          else
            {}.with_indifferent_access
          end

          raw_text = normalized_item[:raw_text].to_s
          quantity = normalize_quantity(normalized_item[:quantity])
          quantity_unit = normalized_item[:quantity_unit]
          quantity_fraction_invalid = integer_quantity_fraction?(quantity, quantity_unit)
          quantity = BigDecimal("1") if quantity_fraction_invalid
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
          if negative_item_amount?(price:, original_line_total:, line_total:)
            skipped_negative_items << {
              raw_text: raw_text,
              amount: [ price, original_line_total, line_total ].compact.map(&:to_i).find(&:negative?)&.abs
            }.compact
            next
          end
          raw_category = normalized_item[:category].presence
          category = normalize_category(raw_category)
          category_invalid = raw_category.present? && category.nil?
          tax_rate = normalize_rate(normalized_item[:tax_rate])
          tax_rate_confidence = normalize_tax_rate_confidence(normalized_item[:tax_rate_confidence])
          review_reasons = item_review_reasons(
            normalized_item,
            tax_rate_confidence:,
            category_invalid:,
            quantity_fraction_invalid:
          )

          {
            # Azure Items[].Description / Name -> receipt_items.raw_text
            raw_text: raw_text,
            suggested_name: normalized_item[:suggested_name].presence || extract_item_name(raw_text),
            # AI は confirmed_name を返さず、補完候補は suggested_name に保持する。
            confirmed_name: normalized_item[:confirmed_name],
            category: category_invalid ? nil : (category || detect_category(raw_text)),
            price: price,
            quantity: quantity,
            original_line_total: original_line_total,
            discount_amount: discount_amount,
            discount_rate: normalize_rate(normalized_item[:discount_rate]),
            # Azure Items[].QuantityUnit -> receipt_items.quantity_unit
            quantity_unit: quantity_unit,
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
              category_invalid: category_invalid,
              quantity_fraction_invalid: quantity_fraction_invalid
            ),
            review_reasons: review_reasons,
            position_index: normalized_item[:position_index] || normalized_item[:index] || index + 1,
            confidence: normalize_confidence(normalized_item[:confidence])
          }
        end
      end

      def build_receipt_adjustments_attributes(ai_adjustments, ocr_adjustment_candidates, lines)
        source = Array(ai_adjustments).present? ? "ai" : "ocr"
        adjustments = if source == "ai"
          Array(ai_adjustments)
        else
          fallback_ocr_adjustments(ocr_adjustment_candidates)
        end

        Array(adjustments).filter_map.with_index do |adjustment, index|
          next unless adjustment.is_a?(Hash) || adjustment.respond_to?(:to_h)

          normalized = (adjustment.is_a?(Hash) ? adjustment : adjustment.to_h).with_indifferent_access
          amount = normalize_amount(normalized[:amount]).to_i.abs
          next unless amount.positive?

          source_line_index = normalize_non_negative_integer(normalized[:source_line_index])
          next unless adjustment_amount_supported_by_ocr?(amount:, source_line_index:, lines:)

          kind = ReceiptAdjustment::KINDS.include?(normalized[:kind].to_s) ? normalized[:kind].to_s : "other"
          sign_value = normalized[:sign].presence || normalized[:sign_hint]
          sign = ReceiptAdjustment::SIGNS.include?(sign_value.to_s) ? sign_value.to_s : default_adjustment_sign(kind)
          review_reasons = normalize_review_reasons(normalized[:review_reasons])
          needs_review = source == "ocr" || normalized[:needs_review] == true
          if kind == "other" || normalized[:kind].blank? || sign_value.blank?
            needs_review = true
            review_reasons << ADJUSTMENT_UNCERTAIN_REVIEW_REASON
          end

          {
            kind: kind,
            label: normalized[:label].to_s.strip.presence,
            amount: amount,
            sign: sign,
            tax_rate: normalize_rate(normalized[:tax_rate] || normalized[:tax_rate_hint]),
            source: source,
            source_text: normalized[:source_text].to_s.strip.presence || lines[source_line_index],
            source_line_index: source_line_index,
            confidence: normalize_confidence(normalized[:confidence]),
            needs_review: needs_review,
            review_reasons: review_reasons.uniq,
            position_index: normalized[:position_index] || index + 1
          }.compact
        end
      end

      def fallback_ocr_adjustments(ocr_adjustment_candidates)
        Array(ocr_adjustment_candidates).filter_map do |candidate|
          next unless candidate.is_a?(Hash) || candidate.respond_to?(:to_h)

          normalized = (candidate.is_a?(Hash) ? candidate : candidate.to_h).with_indifferent_access
          confidence = normalize_confidence(normalized[:confidence])
          next if confidence.nil? || BigDecimal(confidence.to_s) < OCR_ADJUSTMENT_FALLBACK_CONFIDENCE_THRESHOLD

          sign = normalized[:sign_hint].to_s
          next unless ReceiptAdjustment::SIGNS.include?(sign)

          amount = normalize_amount(normalized[:amount]).to_i.abs
          next unless amount.positive?

          source_text = normalized[:source_text].to_s.strip
          {
            kind: infer_ocr_adjustment_kind(source_text, sign),
            label: source_text.presence,
            amount: amount,
            sign: sign,
            tax_rate: normalized[:tax_rate_hint],
            source_text: source_text.presence,
            source_line_index: normalized[:source_line_index],
            confidence: confidence,
            needs_review: true,
            review_reasons: [ ADJUSTMENT_UNCERTAIN_REVIEW_REASON ]
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
        # 税詳細は保存できる場合のみ保存し、金額計算/サマリー表示の補助情報として利用する
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

      def apply_single_tax_detail_rate_policy(items, adjustments, tax_details, receipt_attributes)
        return unless items.present?

        override_rate = single_tax_detail_rate_covering_total(tax_details, receipt_attributes)
        if override_rate
          changed_item_count = apply_tax_rate_to_items(items, override_rate)
          changed_adjustment_count = apply_tax_rate_to_taxable_adjustments(adjustments, override_rate)

          if changed_item_count.positive? || changed_adjustment_count.positive?
            return {
              reason: "single_tax_detail_total_matches_receipt_total",
              source: "printed_tax_detail",
              rate: override_rate.to_s("F"),
              item_count: changed_item_count,
              adjustment_count: changed_adjustment_count
            }
          end
        end

        apply_single_tax_detail_rate_to_unrated_items(items, tax_details)
        nil
      end

      def apply_tax_detail_amount_match_policy(items, adjustments, tax_details)
        usable_tax_details = usable_tax_details_with_target_amount(tax_details)
        return nil unless usable_tax_details.size > 1

        entries_by_amount = tax_rate_match_entries(items, adjustments).group_by { |entry| entry[:amount] }
        tax_details_by_amount = usable_tax_details.group_by { |tax_detail| tax_detail[:target_amount] }
        matches = []

        usable_tax_details.each do |tax_detail|
          next unless tax_details_by_amount[tax_detail[:target_amount]].one?

          entries = entries_by_amount[tax_detail[:target_amount]]
          next unless entries&.one?

          entry = entries.first
          current_rate = normalize_rate(entry[:record][:tax_rate])
          next if current_rate == tax_detail[:rate]

          entry[:record][:tax_rate] = tax_detail[:rate]
          matches << {
            target: entry[:type],
            amount: tax_detail[:target_amount],
            rate: tax_detail[:rate].to_s("F")
          }
        end

        return nil if matches.blank?

        {
          reason: "tax_detail_amount_match",
          source: "printed_tax_detail",
          matches: matches,
          item_count: matches.count { |match| match[:target] == "item" },
          adjustment_count: matches.count { |match| match[:target] == "adjustment" }
        }
      end

      def usable_tax_details_with_target_amount(tax_details)
        Array(tax_details).filter_map do |tax_detail|
          rate = normalize_rate(tax_detail[:rate])
          amount = normalize_amount(tax_detail[:amount])
          target_amount = normalize_amount(tax_detail[:net_amount])
          next unless rate&.positive?
          next unless amount&.positive?
          next unless target_amount&.positive?

          {
            rate: rate,
            amount: amount,
            target_amount: target_amount.to_i
          }
        end
      end

      def tax_rate_match_entries(items, adjustments)
        item_entries = Array(items).filter_map do |item|
          amount = normalize_amount(item[:line_total])
          next unless amount&.positive?

          {
            type: "item",
            amount: amount.to_i,
            record: item
          }
        end

        adjustment_entries = Array(adjustments).filter_map do |adjustment|
          next unless taxable_adjustment?(adjustment)

          amount = normalize_amount(adjustment[:amount])
          next unless amount&.positive?

          {
            type: "adjustment",
            amount: amount.to_i,
            record: adjustment
          }
        end

        item_entries + adjustment_entries
      end

      def apply_single_tax_detail_rate_to_unrated_items(items, tax_details)
        return unless items.all? { |item| item[:tax_rate].nil? }

        rates = Array(tax_details).filter_map do |tax_detail|
          rate = normalize_rate(tax_detail[:rate])
          amount = normalize_amount(tax_detail[:amount])
          next unless rate&.positive?
          next unless amount&.positive?

          rate
        end.uniq
        return unless rates.one?

        items.each { |item| item[:tax_rate] = rates.first }
      end

      def single_tax_detail_rate_covering_total(tax_details, receipt_attributes)
        total_amount = normalize_amount(receipt_attributes[:total_amount])
        return nil unless total_amount&.positive?

        usable_tax_details = Array(tax_details).filter_map do |tax_detail|
          rate = normalize_rate(tax_detail[:rate])
          amount = normalize_amount(tax_detail[:amount])
          next unless rate&.positive?
          next unless amount&.positive?

          {
            rate: rate,
            amount: amount,
            net_amount: normalize_amount(tax_detail[:net_amount])
          }
        end
        return nil unless usable_tax_details.one?

        tax_detail = usable_tax_details.first
        return tax_detail[:rate] if tax_detail_covers_total_amount?(tax_detail, total_amount)

        nil
      end

      def tax_detail_covers_total_amount?(tax_detail, total_amount)
        amount = tax_detail[:amount]
        net_amount = tax_detail[:net_amount]
        total = total_amount.to_i

        return true if net_amount&.positive? && (net_amount.to_i + amount.to_i == total)
        return true if net_amount&.positive? && net_amount.to_i == total && tax_amount_matches_inclusive_total?(total_amount, amount, tax_detail[:rate])

        tax_amount_matches_inclusive_total?(total_amount, amount, tax_detail[:rate])
      end

      def tax_amount_matches_inclusive_total?(total_amount, amount, rate)
        tax = BigDecimal(total_amount.to_s) * rate / (BigDecimal("1") + rate)
        %i[floor round ceil].any? do |rounding_mode|
          Amounts::Rounding.apply_rounding(tax, rounding_mode) == amount.to_i
        end
      end

      def apply_tax_rate_to_items(items, rate)
        Array(items).count do |item|
          next false if normalize_rate(item[:tax_rate]) == rate

          item[:tax_rate] = rate
          true
        end
      end

      def apply_tax_rate_to_taxable_adjustments(adjustments, rate)
        Array(adjustments).count do |adjustment|
          next false unless taxable_adjustment?(adjustment)
          next false if normalize_rate(adjustment[:tax_rate]) == rate

          adjustment[:tax_rate] = rate
          true
        end
      end

      def taxable_adjustment?(adjustment)
        adjustment[:amount].to_i.positive? && adjustment[:kind].to_s != "point_usage"
      end

      def normalize_receipt_attributes(attributes)
        return {} unless attributes.is_a?(Hash)

        symbolized = attributes.deep_symbolize_keys

        {
          store_name: symbolized[:store_name],
          store_address: symbolized[:store_address],               # AI側で補完された値も住所として表示/編集対象にする
          store_address_components: normalize_store_address_components(symbolized[:store_address_components]),
          store_phone_number: symbolized[:store_phone_number],
          purchased_at: symbolized[:purchased_at],
          purchased_at_text: symbolized[:purchased_at_text],
          total_amount: normalize_amount(symbolized[:total_amount]),
          subtotal_amount: normalize_amount(symbolized[:subtotal_amount]),
          tax_amount: normalize_amount(symbolized[:tax_amount]),
          tax_rate: normalize_rate(symbolized[:tax_rate]),
          tip_amount: normalize_amount(symbolized[:tip_amount]),   # NOTE: AI側から来ても現状未使用に近い
          currency_code: normalize_currency_code(symbolized[:currency_code]),
          country_region: normalize_country_region(symbolized[:country_region]), # 国判定/AI promptの補助に使う。UIでは表示しない
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

      def negative_item_amount?(price:, original_line_total:, line_total:)
        [ price, original_line_total, line_total ].compact.any? { |amount| amount.to_i.negative? }
      end

      def skipped_negative_adjustment_review_reasons(skipped_negative_items, receipt_adjustments)
        return [] if skipped_negative_items.blank?

        adjustment_amounts = Array(receipt_adjustments).map { |adjustment| adjustment[:amount].to_i }.select(&:positive?)
        unmatched = skipped_negative_items.any? do |item|
          amount = item[:amount].to_i
          amount <= 0 || !adjustment_amounts.include?(amount)
        end

        unmatched ? [ ADJUSTMENT_UNCERTAIN_REVIEW_REASON ] : []
      end

      def adjustment_amount_supported_by_ocr?(amount:, source_line_index:, lines:)
        return false if source_line_index.nil?

        context = []
        context << lines[source_line_index - 1] if source_line_index.positive?
        context << lines[source_line_index]
        context << lines[source_line_index + 1]
        context.compact!
        context.any? { |text| adjustment_amounts_in_text(text).include?(amount.to_i.abs) }
      end

      def adjustment_amounts_in_text(text)
        text.to_s.scan(ADJUSTMENT_AMOUNT_CANDIDATE_PATTERN).map do |match|
          normalize_amount(match).to_i.abs
        end.select(&:positive?)
      end

      def default_adjustment_sign(kind)
        %w[service_charge late_night_charge delivery_fee bag_fee handling_fee].include?(kind.to_s) ? "surcharge" : "discount"
      end

      def infer_ocr_adjustment_kind(source_text, sign)
        text = source_text.to_s
        return "return_refund" if text.match?(/返品|返金|返却|refund|return/i)
        return "coupon" if text.match?(/クーポン|coupon/i)
        return "point_usage" if text.match?(/ポイント利用|point\s*use|points?\s*redeemed/i)
        return "receipt_discount" if text.match?(/値引|割引|discount|off/i)
        return "late_night_charge" if text.match?(/深夜|late.?night|midnight|after.?hours/i)
        return "service_charge" if text.match?(/サービス料|service\s*charge/i)
        return "delivery_fee" if text.match?(/配送料|送料|delivery|shipping/i)
        return "bag_fee" if text.match?(/レジ袋|袋代|bag/i)
        return "handling_fee" if text.match?(/手数料|handling|fee|charge/i) && sign == "surcharge"

        "other"
      end

      def normalize_non_negative_integer(value)
        return nil if value.blank?

        integer = Integer(value)
        integer >= 0 ? integer : nil
      rescue ArgumentError, TypeError
        nil
      end

      def normalize_country_region(value)
        value.to_s.strip.upcase.presence
      end

      def normalize_currency_code(value)
        value.to_s.strip.upcase.presence
      end

      def normalize_store_address_components(value)
        return nil if value.blank?
        return value.deep_stringify_keys if value.is_a?(Hash)

        nil
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

          # quantity_unit / product_code はOCR優先で保持する。
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

      def final_item_needs_review(normalized_item, ai_items_present:, tax_rate:, tax_rate_confidence:, review_reasons:, category_invalid:, quantity_fraction_invalid: false)
        return true if category_invalid
        return true if quantity_fraction_invalid
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

      def item_review_reasons(normalized_item, tax_rate_confidence:, category_invalid: false, quantity_fraction_invalid: false)
        normalize_review_reasons(normalized_item[:review_reasons]).tap do |reasons|
          reasons << "item_category_uncertain" if category_invalid
          reasons << "item_quantity_uncertain" if quantity_fraction_invalid
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
        # OCR Items[] が取れない場合の最終fallback。現状は review_needed 前提
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

        ReceiptAmountService.parse_amount_or_nil(amount_text)
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
        # OCR fieldの payment_method_text は支払い文脈が強い場合に優先し、
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
        # 最終カテゴリ精度はAI担当。ここは OCR only / AI失敗時の簡易fallback
        Analysis::ReceiptFallbackPatterns.detect_category(text)
      end

      def parse_purchased_at(value)
        return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
        return nil if value.blank?

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def parse_purchased_at_with_time_fallback(ai_attrs, candidates, lines)
        explicit_ai_value = parse_purchased_at(ai_attrs[:purchased_at])
        return explicit_ai_value if explicit_ai_value.present?

        ai_text = ai_attrs[:purchased_at_text].presence
        parsed_ai_text = parse_purchased_at(ai_text)
        return parsed_ai_text if parsed_ai_text.present? && !date_only_text?(ai_text)

        candidate_text = candidates[:purchased_at_text].presence
        parsed_candidate_text = parse_purchased_at(candidate_text)
        return parsed_candidate_text if parsed_candidate_text.present? && !date_only_text?(candidate_text)

        date_text = ai_text.presence || candidate_text
        parsed_date = parsed_ai_text || parsed_candidate_text
        return parsed_date unless parsed_date.present? && date_only_text?(date_text)

        time_candidate = extract_unique_time_candidate_detail(
          Array(candidates[:purchased_at_candidates]) +
            Array(candidates[:purchase_context_lines]) +
            Array(lines)
        )
        return parsed_date if time_candidate.blank?

        parse_purchased_at("#{parsed_date.strftime('%Y-%m-%d')} #{time_candidate[:time]}") || parsed_date
      end

      def build_params_corrections(purchased_at_fallback:, tax_rate_correction:)
        {
          purchased_at_fallback: purchased_at_fallback,
          tax_rate_correction: tax_rate_correction
        }.compact
      end

      def purchased_at_fallback_snapshot(ai_attrs, candidates, lines)
        explicit_ai_value = parse_purchased_at(ai_attrs[:purchased_at])
        return { applied: false, source: "ai_purchased_at" } if explicit_ai_value.present?

        ai_text = ai_attrs[:purchased_at_text].presence
        parsed_ai_text = parse_purchased_at(ai_text)
        return { applied: false, source: "ai_purchased_at_text" } if parsed_ai_text.present? && !date_only_text?(ai_text)

        candidate_text = candidates[:purchased_at_text].presence
        parsed_candidate_text = parse_purchased_at(candidate_text)
        if parsed_candidate_text.present? && !date_only_text?(candidate_text)
          return { applied: false, source: "ocr_purchased_at_text" }
        end

        date_text = ai_text.presence || candidate_text
        parsed_date = parsed_ai_text || parsed_candidate_text
        unless parsed_date.present? && date_only_text?(date_text)
          return {
            applied: false,
            reason: "date_candidate_missing_or_not_date_only"
          }
        end

        time_candidate = extract_unique_time_candidate_detail(
          Array(candidates[:purchased_at_candidates]) +
            Array(candidates[:purchase_context_lines]) +
            Array(lines)
        )
        if time_candidate.blank?
          return {
            applied: false,
            reason: "unique_time_candidate_missing",
            date_text: date_text
          }
        end

        result = parse_purchased_at("#{parsed_date.strftime('%Y-%m-%d')} #{time_candidate[:time]}")
        return { applied: false, reason: "combined_datetime_parse_failed", date_text: date_text } if result.blank?

        {
          applied: true,
          source: "ocr_time_candidate",
          date_text: date_text,
          time_text: time_candidate[:raw_time_text],
          normalized_time: time_candidate[:time],
          ignored_prefix: time_candidate[:ignored_prefix],
          source_text: time_candidate[:source_text],
          result: result.strftime("%Y-%m-%d %H:%M")
        }.compact
      end

      def date_only_text?(value)
        text = value.to_s.strip
        return false if text.blank?
        return false if extract_time_expression(text).present?

        text.match?(/\d{4}[\/\-年]\d{1,2}[\/\-月]\d{1,2}日?/) ||
          text.match?(/\d{1,2}[\/\-]\d{1,2}[\/\-]\d{1,2,4}/)
      end

      def extract_unique_time_candidate(values)
        extract_unique_time_candidate_detail(values)&.fetch(:time)
      end

      def extract_unique_time_candidate_detail(values)
        candidates = Array(values).filter_map do |value|
          text = value.to_s.strip
          next if text.blank?
          next unless purchase_time_context_line?(text)

          extract_time_expression_detail(text)
        end.uniq { |candidate| candidate[:time] }

        candidates.one? ? candidates.first : nil
      end

      def purchase_time_context_line?(text)
        return false if text.match?(/予約|注文|受付|発行|有効期限|期限|期間|販売期間/)

        extract_time_expression(text).present?
      end

      def extract_time_expression(text)
        extract_time_expression_detail(text)&.fetch(:time)
      end

      def extract_time_expression_detail(text)
        match = text.to_s.match(/(?:\A|[^\d])([01]?\d|2[0-3])(?:[:：]|時)([0-5]\d)分?(?:\z|[^\d])/)
        return nil unless match

        raw_end = match.end(2)
        raw_time_text = text[match.begin(1)...raw_end].to_s
        raw_time_text += "分" if text[raw_end] == "分"

        {
          time: "#{match[1].to_i.to_s.rjust(2, '0')}:#{match[2]}",
          raw_time_text: raw_time_text,
          ignored_prefix: text[0...match.begin(1)].to_s.strip.presence,
          source_text: text.to_s.strip
        }
      end

      def normalize_amount(value)
        ReceiptAmountService.parse_amount_or_nil(value)
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
        quantity = ReceiptAmountService.parse_quantity(value, default: BigDecimal("1"))

        quantity.positive? ? quantity : BigDecimal("1")
      end

      def integer_quantity_fraction?(quantity, quantity_unit)
        return false if quantity.blank?
        return false if ReceiptItem.decimal_quantity_unit?(quantity_unit)

        BigDecimal(quantity.to_s).frac != 0
      rescue ArgumentError
        false
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
