module Ai
  class PromptBuilder
    MAX_FILTERED_CONTENT_LINES = 40
    MAX_FULL_CONTEXT_LINES = 150
    MAX_RAW_TEXT_LENGTH = 4_000
    MAX_PURCHASE_CANDIDATES = 5

    class << self
      def build(ocr_result, ai_name_completion_enabled: false)
        new(ocr_result, ai_name_completion_enabled: ai_name_completion_enabled).build
      end

      def filtered_content_lines_max
        prompt_limit_for("limits.ai_prompt_filtered_content_lines_max", MAX_FILTERED_CONTENT_LINES)
      end

      def full_context_lines_max
        prompt_limit_for("limits.ai_prompt_full_context_lines_max", MAX_FULL_CONTEXT_LINES)
      end

      def raw_text_length_max
        prompt_limit_for("limits.ai_prompt_raw_text_length_max", MAX_RAW_TEXT_LENGTH)
      end

      def purchase_candidates_max
        prompt_limit_for("limits.ai_prompt_purchase_candidates_max", MAX_PURCHASE_CANDIDATES)
      end

      def prompt_limit_for(key, fallback)
        SystemSettings.limit_for(key)
      rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
        fallback
      end
    end

    def initialize(ocr_result, ai_name_completion_enabled: false)
      @ocr_result = ocr_result || {}
      @ai_name_completion_enabled = ai_name_completion_enabled == true
    end

    def build
      raise ArgumentError, "ocr_result must be successful" unless success?

      {
        filtered_content: filtered_content,
        full_context_lines: build_full_context_lines,
        store: build_store_payload,
        purchase: build_purchase_payload,
        payment: build_payment_payload,
        tax: build_tax_payload,
        items: build_items_payload,
        adjustment_candidates: build_adjustment_candidates_payload,
        adjustment_context_lines: build_adjustment_context_lines,
        profile_hints: build_profile_hints,
        meta: build_meta
      }
    end

    private

    attr_reader :ocr_result, :ai_name_completion_enabled

    def success?
      fetch(ocr_result, :success) == true
    end

    def build_store_payload
      options = store_name_options
      {
        store_name: candidate_value(:store_name),
        name_options: options,
        name_layout: store_name_layout(options),
        store_address: candidate_value(:store_address),
        store_phone_number: candidate_value(:store_phone_number),
        operator_candidates: operator_candidates,
        address_candidates: address_candidates
      }.compact
    end

    def build_purchase_payload
      {
        purchased_at_text: candidate_value(:purchased_at_text),
        purchased_at_candidates: purchased_at_candidates,
        purchase_context_lines: purchase_context_lines,
        purchased_at_evidence: purchased_at_evidence
      }.compact
    end

    def purchased_at_evidence
      return unless candidates.key?(:purchased_at_evidence) || candidates.key?("purchased_at_evidence")

      @purchased_at_evidence ||= Analysis.purchased_at_evidence(
        candidate_value(:purchased_at_evidence) || {},
        max_candidates: self.class.purchase_candidates_max
      )
    end

    def store_name_options
      options = Analysis.store_name_options(ocr_result: ocr_result, version: "store_name_options_v2")
      options.slice(:schema_version, :checksum, :truncated, :invalid).merge(
        options: options[:options].map { |option| option.slice(:option_id, :value, :candidate_ids, :line_indexes) },
        relations: options.fetch(:relations, []).map do |relation|
          relation.slice(
            :relation_id, :candidate_ids, :same_name_option_ids, :store_location_option_ids, :separate_option_ids,
            :left_complete_option_ids, :right_complete_option_ids
          )
        end
      )
    end

    def store_name_layout(options)
      return if options[:invalid] || options[:truncated]

      evidence = Analysis.store_name_evidence(candidate_value(:store_name_evidence))
      layout = Analysis.store_name_layout(fetch(meta_hash, :store_name_layout), evidence:)
      return unless layout

      referenced_ids = (options[:options] + options[:relations]).flat_map { |entry| entry[:candidate_ids] }.to_h { |id| [ id, true ] }
      candidates_by_id = evidence[:candidates].index_by { |candidate| candidate[:candidate_id] }
      entries = layout[:entries].filter_map do |entry|
        next unless referenced_ids[entry[:candidate_id]]

        candidate = candidates_by_id.fetch(entry[:candidate_id])
        coverage = entry[:line_span] == candidate[:span] ? "full_line" : "partial_line"
        entry.merge(coverage:)
      end
      layout.merge(entries:) if entries.any?
    end

    def build_payment_payload
      method_text = candidate_value(:payment_method_text)

      candidates = normalize_payment_candidates
      if method_text.present?
        candidates = [ { method: method_text } ] + candidates
      end

      context_lines = payment_context_lines
      if method_text.present?
        context_lines = ([ method_text ] + context_lines).uniq
      end

      {
        payment_method: candidate_value(:payment_method),
        payment_method_text: method_text,
        payment_candidates: candidates,
        payment_context_lines: context_lines,
        printed_payments: normalize_printed_payments
      }.compact
    end

    def build_tax_payload
      {
        tax_rate: normalize_tax_rate(candidate_value(:tax_rate)),
        tax_amount: normalize_number(candidate_value(:tax_amount)),
        total_amount: normalize_number(candidate_value(:total_amount)),
        tax_details: normalize_tax_details,
        tax_context_lines: tax_context_lines
      }.compact
    end

    def build_items_payload
      @items_payload ||= begin
        # items は OCR構造化結果を基準にしつつ、matched_content_lines / matched_filtered_content_lines で
        # filtered_content 側の文脈も AI に渡す。商品名補完時は raw_text 単独ではなく content 文脈も参照させる。
        Array(candidate_value(:items)).each_with_index.map do |item, index|
          normalize_item_payload(item, index)
        end.compact
      end
    end

    def build_adjustment_context_lines
      @adjustment_context_lines ||= build_full_context_lines
    end

    def build_adjustment_candidates_payload
      @adjustment_candidates_payload ||= Array(candidate_value(:adjustment_candidates)).filter_map do |candidate|
        next unless candidate.is_a?(Hash)

        {
          source_text: fetch(candidate, :source_text),
          source_line_index: normalize_number(fetch(candidate, :source_line_index)),
          neighboring_texts: normalize_neighboring_texts(fetch(candidate, :neighboring_texts)),
          amount: normalize_number(fetch(candidate, :amount)),
          sign_hint: fetch(candidate, :sign_hint),
          tax_rate_hint: normalize_tax_rate(fetch(candidate, :tax_rate_hint)),
          confidence: normalize_decimal(fetch(candidate, :confidence)),
          candidate_reason: fetch(candidate, :candidate_reason),
          needs_review: fetch(candidate, :needs_review)
        }.compact
      end
    end

    def build_full_context_lines
      @full_context_lines ||= lines.first(self.class.full_context_lines_max).map.with_index do |line, index|
        {
          index: index,
          text: line,
          previous_text: index.positive? ? lines[index - 1] : nil,
          next_text: lines[index + 1]
        }.compact
      end
    end

    def normalize_item_payload(item, index)
      return nil unless item.is_a?(Hash)

      raw_text = fetch(item, :raw_text) || fetch(item, :description)

      {
        index: index,
        raw_text: raw_text,
        price: normalize_number(fetch(item, :price)),
        quantity: normalize_number(fetch(item, :quantity)),
        quantity_unit_code: normalize_item_quantity_unit_code(item),
        line_total: normalize_number(fetch(item, :line_total) || fetch(item, :total_price)),
        tax_rate: normalize_tax_rate(fetch(item, :tax_rate)),
        product_code: fetch(item, :product_code),
        confidence: normalize_decimal(fetch(item, :confidence)),
        matched_content_lines: item_content_lines(raw_text),
        matched_filtered_content_lines: item_filtered_content_lines(raw_text)
      }.compact
    end

    def normalize_item_quantity_unit_code(item)
      return nil if fetch(item, :quantity_unit_status).to_s == "unknown"

      value = fetch(item, :quantity_unit_code)
      return ReceiptQuantityUnit.default_code if value.blank?

      ReceiptQuantityUnit.normalize(value, default: nil)
    end

    def build_meta
      {
        ocr_provider: fetch(meta_hash, :provider),
        ocr_model: fetch(meta_hash, :model),
        country_region: candidate_value(:country_region),
        raw_text_length: raw_text.length,
        line_count: lines.length,
        item_count: build_items_payload.length,
        adjustment_candidate_count: build_adjustment_candidates_payload.length,
        confidence_summary: build_confidence_summary,
        ai_name_completion_enabled: ai_name_completion_enabled
      }.compact
    end

    def filtered_content
      @filtered_content ||= filtered_content_lines.join("\n")
    end

    def filtered_content_lines
      @filtered_content_lines ||= lines.reject { |line| removable_noise_line?(line) }.first(self.class.filtered_content_lines_max)
    end

    def removable_noise_line?(line)
      text = line.to_s.strip
      return true if text.empty?

      # 数字・記号だけの行は判定材料として弱い
      return true if text.match?(analysis_profile.ai_numeric_symbol_only_line_pattern)
      return true if text.match?(analysis_profile.ai_masked_card_line_pattern)

      # 店舗 / 購入日時 / 支払い判定に不要な明細・金額ノイズを落とす
      # 支払区分は payment_context_lines の補助材料になり得るためここでは落とさない
      return true if text.match?(analysis_profile.ai_removable_noise_line_pattern)
      return true if text.match?(analysis_profile.ai_percent_line_pattern)

      false
    end

    def purchased_at_candidates
      if purchased_at_evidence
        return purchased_at_evidence[:candidates].filter_map do |candidate|
          next if candidate[:role] == "duration"

          [ candidate[:date], candidate[:time] ].compact.join(" ").presence
        end.uniq
      end

      lines.select { |line| date_time_line?(line) }.uniq.first(self.class.purchase_candidates_max)
    end

    def purchase_context_lines
      candidates = filtered_reference_lines.select do |line|
        line_profile(line)[:purchase_context_line]
      end

      return candidates.first(8) if candidates.present?

      lines.select { |line| line_profile(line)[:purchase_context_line] }.uniq.first(8)
    end

    def payment_context_lines
      candidates = filtered_reference_lines.select do |line|
        line_profile(line)[:payment_context_line]
      end

      return candidates.first(8) if candidates.present?

      lines.select { |line| line_profile(line)[:payment_context_line] }.uniq.first(8)
    end

    def tax_context_lines
      candidates = filtered_reference_lines.select do |line|
        line_profile(line)[:tax_context_line]
      end

      return candidates.first(8) if candidates.present?

      lines.select { |line| line_profile(line)[:tax_context_line] }.uniq.first(8)
    end

    def address_candidates
      candidates = filtered_reference_lines.select do |line|
        line_profile(line)[:address_candidate]
      end

      return candidates.uniq.first(5) if candidates.present?

      lines.select { |line| line_profile(line)[:address_candidate] }.uniq.first(5)
    end

    def operator_candidates
      @operator_candidates ||= Analysis.store_name_operator_candidates(
        lines,
        merchant_name: candidate_value(:store_name)
      )
    end

    def purchase_context_line?(line)
      text = line.to_s.strip
      return false if text.empty?

      date_time_line?(text) ||
        text.match?(analysis_profile.ai_purchase_context_line_pattern)
    end

    def payment_context_line?(line)
      text = line.to_s.strip
      return false if text.empty?

      text.match?(analysis_profile.ai_payment_context_line_pattern)
    end

    def tax_context_line?(line)
      text = line.to_s.strip
      return false if text.empty?

      text.match?(analysis_profile.ai_tax_context_line_pattern)
    end

    def item_content_lines(raw_text)
      item_matching_lines(raw_text)[:content_lines].dup
    end

    def item_filtered_content_lines(raw_text)
      item_matching_lines(raw_text)[:filtered_content_lines].dup
    end

    def item_matching_lines(raw_text)
      @item_matching_lines ||= {}
      key = text_cache_key(raw_text)

      @item_matching_lines[key] ||= begin
        if raw_text.to_s.strip.empty?
          {
            content_lines: [].freeze,
            filtered_content_lines: [].freeze
          }.freeze
        else
          filtered_matches = item_related_lines(filtered_reference_lines, raw_text)
          content_matches = filtered_matches.present? ? filtered_matches : item_related_lines(lines, raw_text)

          {
            content_lines: content_matches.first(5).freeze,
            filtered_content_lines: filtered_matches.first(5).freeze
          }.freeze
        end
      end
    end

    def item_related_lines(source_lines, raw_text)
      normalized_raw_text = normalize_item_text(raw_text)
      return [] if normalized_raw_text.empty?

      source_lines.select do |line|
        item_related_line?(line, normalized_raw_text)
      end.uniq
    end

    def item_related_line?(line, normalized_raw_text)
      profile = line_profile(line)
      text = profile[:text]
      return false if text.empty?

      normalized_line = profile[:normalized_text]
      return false if normalized_line.empty?
      return false if profile[:address_candidate]
      return false if profile[:payment_context_line]
      return false if profile[:purchase_context_line]

      normalized_line.include?(normalized_raw_text) ||
        normalized_raw_text.include?(normalized_line) ||
        shared_item_token_arrays?(
          profile[:item_tokens],
          item_tokens_for_normalized_text(normalized_raw_text)
        )
    end

    def shared_item_tokens?(normalized_line, normalized_raw_text)
      line_tokens = item_tokens_for_normalized_text(normalized_line)
      raw_tokens = item_tokens_for_normalized_text(normalized_raw_text)
      shared_item_token_arrays?(line_tokens, raw_tokens)
    end

    def shared_item_token_arrays?(line_tokens, raw_tokens)
      return false if line_tokens.empty? || raw_tokens.empty?

      (line_tokens & raw_tokens).any? { |token| token.length >= 2 }
    end

    def normalize_item_text(text)
      @normalized_item_texts ||= {}
      key = text_cache_key(text)
      @normalized_item_texts[key] ||= key.downcase.gsub(/[^a-z0-9\p{Han}\p{Hiragana}\p{Katakana}]/i, "").freeze
    end

    def item_tokens_for_normalized_text(text)
      @item_tokens_for_normalized_text ||= {}
      key = text_cache_key(text)
      @item_tokens_for_normalized_text[key] ||= key.scan(/[a-z0-9\p{Han}\p{Hiragana}\p{Katakana}]+/i).freeze
    end

    def address_candidate?(line)
      text = line.to_s.strip
      return false if text.empty?
      return false if date_time_line?(text)
      return false if text.match?(analysis_profile.ai_branch_numeric_code_pattern)
      return false if text.match?(analysis_profile.ai_address_exclusion_pattern)
      return false if text.match?(analysis_profile.ai_address_registration_noise_pattern)

      text.match?(analysis_profile.ai_address_candidate_pattern)
    end

    def filtered_reference_lines
      @filtered_reference_lines ||= filtered_content_lines
    end

    def line_profile(line)
      @line_profiles ||= {}
      text = text_cache_key(line.to_s.strip)

      @line_profiles[text] ||= begin
        normalized_text = normalize_item_text(text)

        {
          text: text,
          normalized_text: normalized_text,
          item_tokens: item_tokens_for_normalized_text(normalized_text),
          address_candidate: text.present? && address_candidate?(text),
          date_time_line: text.present? && date_time_line?(text),
          payment_context_line: text.present? && payment_context_line?(text),
          purchase_context_line: text.present? && purchase_context_line?(text),
          tax_context_line: text.present? && tax_context_line?(text)
        }.freeze
      end
    end

    def date_time_line?(line)
      text = line.to_s
      analysis_profile.ai_date_time_line_patterns.any? { |pattern| text.match?(pattern) }
    end

    def normalize_payment_candidates
      Array(candidate_value(:payment_candidates)).filter_map do |candidate|
        next unless candidate.is_a?(Hash)

        {
          source: fetch(candidate, :source),
          field_name: fetch(candidate, :field_name),
          method: fetch(candidate, :method),
          raw_text: fetch(candidate, :raw_text),
          content: fetch(candidate, :content),
          amount: normalize_number(fetch(candidate, :amount)),
          confidence: normalize_decimal(fetch(candidate, :confidence))
        }.compact
      end
    end

    def normalize_printed_payments
      Array(candidate_value(:payments)).filter_map do |payment|
        next unless payment.is_a?(Hash)

        {
          method: fetch(payment, :method),
          amount: normalize_number(fetch(payment, :amount)),
          source_line_index: fetch(payment, :source_line_index),
          method_source_line_index: fetch(payment, :method_source_line_index)
        }.compact
      end
    end

    def normalize_tax_details
      Array(candidate_value(:tax_details)).filter_map do |tax_detail|
        next unless tax_detail.is_a?(Hash)

        {
          description: fetch(tax_detail, :description),
          rate: normalize_tax_rate(fetch(tax_detail, :rate)),
          amount: normalize_number(fetch(tax_detail, :amount)),
          net_amount: normalize_number(fetch(tax_detail, :net_amount))
        }.compact
      end
    end

    def normalize_neighboring_texts(value)
      return unless value.is_a?(Hash)

      {
        previous_text: fetch(value, :previous_text),
        next_text: fetch(value, :next_text)
      }.compact.presence
    end

    def items_average_confidence
      values = build_items_payload.filter_map { |item| item[:confidence] }
      return nil if values.empty?

      (values.sum / values.size.to_f).round(3)
    end

    def build_confidence_summary
      meta_summary = fetch(meta_hash, :confidence_summary)
      return meta_summary if meta_summary.is_a?(Hash)

      {
        store_name: normalize_decimal(candidate_confidence(:store_name)),
        purchased_at: normalize_decimal(candidate_confidence(:purchased_at_text)),
        payment_method: normalize_decimal(candidate_confidence(:payment_method)),
        items_average: items_average_confidence
      }.compact
    end

    def lines
      @lines ||= begin
        base_lines = Array(fetch(ocr_result, :lines)).map { |line| line.to_s.strip }.reject(&:empty?)

        if base_lines.present?
          base_lines
        else
          content_text.to_s.lines.map(&:strip).reject(&:empty?)
        end
      end
    end

    def raw_text
      @raw_text ||= fetch(ocr_result, :raw_text).to_s.first(self.class.raw_text_length_max)
    end

    def content_text
      fetch(ocr_result, :content).to_s.presence || raw_text
    end

    def candidates
      @candidates ||= fetch(ocr_result, :candidates) || {}
    end

    def meta_hash
      @meta_hash ||= fetch(ocr_result, :meta) || {}
    end

    def build_profile_hints
      explicit_profile&.ai_profile_hints || {}
    end

    def explicit_profile
      @explicit_profile ||= ReceiptAnalysisProfiles.fetch(candidate_value(:country_region))
    end

    def analysis_profile
      @analysis_profile ||= explicit_profile || ReceiptAnalysisProfiles.default
    end

    def candidate_value(key)
      value = fetch(candidates, key)
      return fetch(value, :value) if value.is_a?(Hash) && value.key?(:value)
      return fetch(value, :value) if value.is_a?(Hash) && value.key?("value")

      value
    end

    def candidate_confidence(key)
      value = fetch(candidates, key)
      return unless value.is_a?(Hash)

      fetch(value, :confidence)
    end

    def normalize_number(value)
      return nil if value.nil?
      return value if value.is_a?(Integer)
      return value.to_i if value.is_a?(Float)

      stripped = value.to_s.gsub(/[^\d\-.]/, "")
      return nil if stripped.empty?

      stripped.include?(".") ? stripped.to_f : stripped.to_i
    end

    def normalize_decimal(value)
      return nil if value.nil?
      return value.round(3) if value.is_a?(Float)
      return value.to_f.round(3) if value.is_a?(Integer)

      stripped = value.to_s.gsub(/[^\d\-.]/, "")
      return nil if stripped.empty?

      stripped.to_f.round(3)
    end

    def normalize_tax_rate(value)
      return nil if value.nil?

      stripped = value.to_s.delete("%").delete("％").gsub(/[^\d\-.]/, "")
      return nil if stripped.empty?

      rate = BigDecimal(stripped)
      rate > 1 ? rate / 100 : rate
    rescue ArgumentError
      nil
    end

    def fetch(object, key)
      return nil unless object.respond_to?(:[])

      object[key] || object[key.to_s] || object[key.to_sym]
    end

    def text_cache_key(text)
      -text.to_s
    end
  end
end
