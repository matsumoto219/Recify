module Analysis
  class StoreNameCandidateClassifier
    MONEY_OR_NUMERIC_PATTERN = /\A[\d\s\-\/:().,*＊¥￥$€£%円]+\z/.freeze

    class << self
      def customer_facing_heading_candidates(lines, max_lines: 8)
        heading_lines = []

        header_lines = Array(lines).first(max_lines)

        header_lines.each_with_index do |line, index|
          text = normalize_name(line)
          next if text.blank?

          break if heading_lines.any? && heading_boundary_line?(text)
          next if heading_lines.empty? && heading_boundary_line?(text)
          next if isolated_logo_fragment_prefix?(text, header_lines:, line_index: index)
          next unless customer_facing_heading_line?(text)

          heading_lines << text
          break if heading_lines.size >= 3
        end

        candidates = []
        preferred_local_name = preferred_local_complete_store_name(heading_lines)
        if preferred_local_name.present?
          candidates << preferred_local_name
        else
          candidates << join_heading_lines(heading_lines) if heading_lines.size > 1
        end
        candidates.concat(heading_lines)
        candidates.compact_blank.uniq
      end

      def latin_logo_prefix_duplicate?(combined_name, local_name)
        combined = normalize_name(combined_name)
        local = normalize_name(local_name)
        return false if combined.blank? || local.blank?
        return false if normalize_compact_name(combined).to_s.casecmp?(normalize_compact_name(local).to_s)
        return false unless local_complete_store_name?(local)

        latin_prefix = latin_prefix_before_local_name(combined, local)
        latin_logo_brand_line?(latin_prefix)
      end

      def complete_local_store_name?(text)
        local_complete_store_name?(text)
      end

      def operator_candidates(lines, merchant_name: nil)
        candidates = []
        normalized_merchant = normalize_name(merchant_name)
        candidates << normalized_merchant if legal_entity_name?(normalized_merchant)

        Array(lines).each_with_index do |line, index|
          text = normalize_name(line)
          next if text.blank?

          if legal_entity_name?(text)
            candidates << legal_entity_with_neighbor(lines, index)
          elsif operator_context_line?(text)
            candidates << legal_entity_after_operator_context(lines, index)
          end
        end

        candidates.filter_map { |candidate| normalize_compact_name(candidate) }.uniq
      end

      def brand_candidate_from_legal_entity(candidate)
        normalized = normalize_name(candidate)
        return nil unless legal_entity_name?(normalized)

        brand = remove_legal_entity_designators(normalized)
        return nil if brand.blank?
        return nil if legal_entity_designator_only?(brand)

        normalize_name(brand)
      end

      def brand_candidates_from_legal_entities(candidates)
        Array(candidates).filter_map { |candidate| brand_candidate_from_legal_entity(candidate) }.uniq
      end

      def legal_entity_name?(text)
        normalize_name(text).to_s.match?(profile.store_legal_entity_pattern)
      end

      def operator_context_line?(text)
        normalize_name(text).to_s.match?(profile.store_operator_context_pattern)
      end

      def descriptive_heading_line?(text)
        normalize_name(text).to_s.match?(profile.store_descriptive_only_heading_pattern)
      end

      def store_message_line?(text)
        normalize_name(text).to_s.match?(profile.store_message_line_pattern)
      end

      def isolated_logo_fragment?(text)
        compacted = normalize_name(text).to_s.gsub(/[[:space:]]+/, "")
        return true if compacted.match?(/\A[[:punct:]]+[A-Za-z]{1,8}\z/)
        return false unless compacted.length == 1

        compacted.match?(/\A(?:\p{Katakana}|[[:punct:]])\z/u)
      end

      def operator_legal_entity_candidate?(candidate, lines)
        normalized_candidate = normalize_name(candidate)
        return false unless legal_entity_name?(normalized_candidate)

        operator_context_near_candidate?(normalized_candidate, lines)
      end

      def valid_candidate?(text, item_names: [])
        normalized = normalize_name(text)
        return false if normalized.blank?

        compacted = normalized.gsub(/[[:space:]]+/, "")
        return false if normalized.match?(profile.ocr_store_name_header_pattern)
        return false if compacted.match?(profile.ocr_store_name_header_pattern)
        return false if compacted.match?(MONEY_OR_NUMERIC_PATTERN)
        return false if compacted.match?(/\A(?:#{profile.analysis_adjustment_amount_candidate_pattern})\z/)
        return false if item_derived_candidate?(normalized, item_names)

        true
      end

      def normalize_name(text)
        text.to_s.unicode_normalize(:nfkc).gsub(/[[:space:]]+/, " ").strip.presence
      end

      def normalize_compact_name(text)
        normalized = normalize_name(text)
        return nil if normalized.blank?

        if japanese_text?(normalized)
          normalized.gsub(/[[:space:]]+/, "")
        else
          normalized.gsub(/[[:space:]]+/, " ")
        end
      end

      private

      def profile
        ReceiptAnalysisProfiles.default
      end

      def customer_facing_heading_line?(text)
        return false if text.length < 2
        return false if text.length > 60
        return false if legal_entity_name?(text)
        return false if operator_context_line?(text)
        return false if heading_boundary_line?(text)
        return false if descriptive_heading_line?(text)
        return false if store_message_line?(text)
        return false if text.match?(MONEY_OR_NUMERIC_PATTERN)

        text.match?(/[一-龠ぁ-んァ-ヶA-Za-z]/)
      end

      def item_derived_candidate?(candidate, item_names)
        compact_candidate = normalize_compact_name(candidate).to_s.downcase
        return false if compact_candidate.blank?

        compact_item_names = Array(item_names).filter_map do |item_name|
          normalized = normalize_compact_name(item_name).to_s.downcase
          normalized if normalized.length >= 2
        end.uniq

        return true if compact_item_names.include?(compact_candidate)
        return true if compact_item_names.any? do |item_name|
          item_name_with_money_only_context?(compact_candidate, item_name)
        end

        compact_item_names.count { |item_name| compact_candidate.include?(item_name) } >= 2
      end

      def item_name_with_money_only_context?(candidate, item_name)
        return false unless candidate.include?(item_name)

        remainder = candidate.sub(item_name, "")
        return false if remainder.blank?

        remainder.match?(/\A(?:#{profile.analysis_adjustment_amount_candidate_pattern})\z/)
      end

      def isolated_logo_fragment_prefix?(line, header_lines:, line_index:)
        return false unless isolated_logo_fragment?(line)
        return false if line_index.nil?

        Array(header_lines)[(line_index + 1)..].to_a.any? do |candidate|
          normalized_candidate = normalize_name(candidate).to_s
          !isolated_logo_fragment?(normalized_candidate) && customer_facing_heading_line?(normalized_candidate)
        end
      end

      def preferred_local_complete_store_name(lines)
        compacted = Array(lines).map { |line| normalize_name(line) }.compact_blank
        return nil if compacted.size < 2

        latin_line = compacted.first
        local_line = compacted.second
        return nil unless latin_logo_brand_line?(latin_line)
        return nil unless local_complete_store_name?(local_line)

        local_line
      end

      def latin_prefix_before_local_name(combined, local)
        compact_combined = normalize_compact_name(combined).to_s
        compact_local = normalize_compact_name(local).to_s
        return nil if compact_combined.blank? || compact_local.blank?
        return nil unless compact_combined.downcase.end_with?(compact_local.downcase)

        compact_combined[0...(compact_combined.length - compact_local.length)]
      end

      def latin_logo_brand_line?(text)
        normalized = normalize_name(text).to_s
        return false if normalized.blank?
        return false if japanese_text?(normalized)
        return false if legal_entity_name?(normalized)
        return false if operator_context_line?(normalized)
        return false if heading_boundary_line?(normalized)
        return false if descriptive_heading_line?(normalized)
        return false if store_message_line?(normalized)
        return false if normalized.match?(MONEY_OR_NUMERIC_PATTERN)

        normalized.match?(/\A[A-Za-z][A-Za-z0-9&.'-]{1,30}\z/)
      end

      def local_complete_store_name?(text)
        normalized = normalize_name(text).to_s
        return false if normalized.blank?
        return false unless japanese_text?(normalized)
        return false if legal_entity_name?(normalized)
        return false if operator_context_line?(normalized)
        return false if heading_boundary_line?(normalized)
        return false if descriptive_heading_line?(normalized)
        return false if store_message_line?(normalized)
        return false if normalized.match?(profile.store_address_like_pattern)
        return false if normalized.match?(MONEY_OR_NUMERIC_PATTERN)
        return false unless normalized.match?(/\A[ァ-ヶー]{2,}/)

        normalized.match?(profile.store_local_complete_name_suffix_pattern)
      end

      def heading_boundary_line?(text)
        normalized = normalize_name(text).to_s
        return true if store_message_line?(normalized)
        return true if normalized.match?(profile.store_heading_stop_pattern)
        return true if normalized.gsub(/[[:space:]]+/, "").match?(profile.store_heading_stop_pattern)
        return true if normalized.match?(profile.store_address_like_pattern)
        return true if normalized.match?(profile.store_date_time_pattern)
        return true if normalized.match?(/\bT\d{13}\b/i)

        false
      end

      def join_heading_lines(lines)
        compacted = Array(lines).map { |line| normalize_name(line) }.compact_blank
        return nil if compacted.blank?

        if compacted.any? { |line| japanese_text?(line) } && !mixed_script_heading?(compacted)
          compacted.join.gsub(/[[:space:]]+/, "")
        else
          compacted.join(" ").gsub(/[[:space:]]+/, " ")
        end
      end

      def mixed_script_heading?(lines)
        Array(lines).any? { |line| line.to_s.match?(/[A-Za-z]/) } &&
          Array(lines).any? { |line| japanese_text?(line) }
      end

      def operator_context_near_candidate?(candidate, lines)
        indexes = candidate_line_indexes(lines, candidate)
        return false if indexes.blank?

        indexes.any? do |index|
          range = ([ index - 3, 0 ].max)..([ index + 3, Array(lines).length - 1 ].min)
          Array(lines)[range].any? { |line| operator_context_line?(line) }
        end
      end

      def candidate_line_indexes(lines, candidate)
        compact_candidate = normalize_compact_name(candidate).to_s.downcase
        return [] if compact_candidate.blank?

        Array(lines).each_with_index.filter_map do |line, index|
          compact_line = normalize_compact_name(line).to_s.downcase
          next if compact_line.blank?

          index if compact_candidate.include?(compact_line) || compact_line.include?(compact_candidate)
        end
      end

      def legal_entity_with_neighbor(lines, index)
        legal_name = normalize_name(Array(lines)[index])
        return legal_name unless legal_entity_designator_only?(legal_name)

        parts = [ legal_name ]
        neighbor = following_name_line(lines, index)
        parts << neighbor if neighbor.present?

        join_heading_lines(parts)
      end

      def legal_entity_designator_only?(text)
        normalize_name(text).to_s.match?(profile.store_legal_entity_designator_only_pattern)
      end

      def remove_legal_entity_designators(text)
        normalized = normalize_name(text).to_s
        brand = remove_japanese_legal_designators(normalized)
        brand = remove_english_legal_designators(brand)

        normalize_name(brand)
      end

      def remove_japanese_legal_designators(text)
        text
          .sub(profile.store_japanese_legal_designator_prefix_pattern, "")
          .sub(profile.store_japanese_legal_designator_suffix_pattern, "")
      end

      def remove_english_legal_designators(text)
        brand = text.to_s.strip
        removed_strong_suffix = false

        loop do
          next_brand = brand.sub(
            /\s*,?\s*(?:co\.?\s*,?\s*ltd\.?|pty\s+ltd|pvt\.?\s+ltd|s\.?\s*a\.?\s*s\.?|s\.?\s*a\.?|inc\.?|incorporated|ltd\.?|limited|llc|gmbh|ag|bv|nv|plc|corp\.?|corporation)\.?\z/i,
            ""
          ).strip
          break if next_brand == brand

          brand = next_brand
          removed_strong_suffix = true
        end

        brand = brand.sub(/\s*,?\s*company\.?\z/i, "").strip unless removed_strong_suffix
        brand
      end

      def legal_entity_after_operator_context(lines, index)
        lookahead = Array(lines)[(index + 1)..(index + 4)]
        legal_index = lookahead&.find_index { |line| legal_entity_name?(line) }
        return nil if legal_index.nil?

        legal_entity_with_neighbor(lines, index + 1 + legal_index)
      end

      def following_name_line(lines, index)
        Array(lines)[(index + 1)..(index + 4)]&.find do |line|
          text = normalize_name(line)
          next false if text.blank?
          next false if heading_boundary_line?(text)
          next false if operator_name_noise_line?(text)
          next false if text.match?(MONEY_OR_NUMERIC_PATTERN)

          text.match?(/[一-龠ぁ-んァ-ヶA-Za-z]/)
        end
      end

      def operator_name_noise_line?(text)
        normalized = normalize_name(text).to_s
        normalized.match?(/\A\d+[[:alpha:]一-龠ぁ-んァ-ヶ]{0,2}\z/)
      end

      def japanese_text?(text)
        text.to_s.match?(/[一-龠ぁ-んァ-ヶ]/)
      end
    end
  end
end
