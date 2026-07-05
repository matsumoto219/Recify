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
      @profile = ReceiptAnalysisProfiles.default
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

    attr_reader :ocr_result, :profile

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
        line.match?(profile.signal_receipt_amount_context_pattern) &&
          amount_like_text?(line)
      end
    end

    def receipt_word?
      text_lines.any? { |line| line.match?(profile.signal_receipt_word_pattern) }
    end

    def money_like_item_lines_score
      [ money_like_item_lines_count, 3 ].min
    end

    def money_like_item_lines_count
      @money_like_item_lines_count ||= text_lines.count { |line| money_like_item_line?(line) }
    end

    def money_like_item_line?(line)
      normalized = line.to_s
      return false if normalized.match?(profile.signal_non_item_context_pattern)
      return false unless normalized.match?(/[一-龠ぁ-んァ-ヶA-Za-z]/)

      amount_like_text?(normalized)
    end

    def amount_like_text?(text)
      normalized = text.to_s
      return true if normalized.match?(profile.signal_money_prefix_pattern)
      return true if normalized.match?(profile.signal_money_suffix_pattern)
      return false if normalized.match?(profile.signal_date_pattern)

      normalized.match?(profile.signal_generic_amount_pattern)
    end

    def purchased_at_signal?
      candidates[:purchased_at_text].present? || date_time_pattern?
    end

    def date_time_pattern?
      text_lines.any? do |line|
        profile.signal_date_time_patterns.any? { |pattern| line.match?(pattern) }
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
        text_lines.any? { |line| line.match?(profile.signal_phone_pattern) }
    end

    def address_signal?
      candidates[:store_address].present? ||
        text_lines.any? { |line| line.match?(profile.signal_address_pattern) }
    end

    def registration_number_signal?
      text_lines.any? { |line| line.match?(profile.signal_registration_number_pattern) }
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

      normalized_text = text_lines.join("\n")

      profile.signal_household_budget_keywords.count { |keyword| normalized_text.include?(keyword) } >= 4
    end

    def marketing_web_page_context?
      return false if receipt_word? || payments? || payment_method_text? || tax_details?

      normalized_text = text_lines.join("\n")

      profile.signal_marketing_web_page_patterns.count { |pattern| normalized_text.match?(pattern) } >= 3
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
      normalized_text = text_lines.join("\n")

      profile.signal_menu_context_patterns.count { |pattern| normalized_text.match?(pattern) }
    end

    def catalog_context_score
      normalized_text = text_lines.join("\n")

      profile.signal_catalog_context_patterns.count { |pattern| normalized_text.match?(pattern) }
    end

    def social_context_score
      normalized_text = text_lines.join("\n")

      profile.signal_social_context_patterns.count { |pattern| normalized_text.match?(pattern) }
    end

    def flyer_context_score
      normalized_text = text_lines.join("\n")

      profile.signal_flyer_context_patterns.count { |pattern| normalized_text.match?(pattern) }
    end

    def pdf_document_context_score
      normalized_text = text_lines.join("\n")

      profile.signal_pdf_document_context_patterns.count { |pattern| normalized_text.match?(pattern) }
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
