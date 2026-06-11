module Analysis
  class StoreNameCandidateClassifier
    LEGAL_ENTITY_PATTERN = /
      株式会社|有限会社|合同会社|合名会社|合資会社|一般社団法人|一般財団法人|公益社団法人|公益財団法人|
      \b(?:inc\.?|incorporated|ltd\.?|limited|llc|gmbh|ag|bv|nv|plc|corp\.?|corporation|company)\b|
      \b(?:co\.?\s*,?\s*ltd\.?|pty\s+ltd|pvt\.?\s+ltd|s\.?\s*a\.?|s\.?\s*a\.?\s*s\.?)\b
    /ix.freeze

    OPERATOR_CONTEXT_PATTERN = /
      指定管理者|運営会社|管理会社|受託会社|委託先|管理者|運営者|登録事業者|適格請求書発行事業者|
      operated\s+by|managed\s+by|management\s+company|operator|licensee|franchisee|franchise\s+owner|
      contractor|concessionaire|tax[-\s]*registered|registered\s+(?:entity|business|merchant|company)|
      legal\s+entity|merchant\s+of\s+record|trading\s+as
    /ix.freeze

    HEADING_STOP_PATTERN = /
      領収書|領収証|レシート|receipt|登録番号|インボイス|適格請求書|tax\s*(?:id|number)|vat\s*(?:id|number)|
      tel|電話|fax|住所|所在地|合計|小計|消費税|税率|税額|税込|税抜|現計|支払|お支払|決済|点数|
      total|subtotal|tax|payment|cash|change
    /ix.freeze

    ADDRESS_LIKE_PATTERN = /
      [都道府県].*\d|[市区町村郡].*\d|〒|\d+[-丁目番地号]|
      \b(?:street|st\.|road|rd\.|avenue|ave\.|blvd\.|drive|dr\.|suite|floor)\b.*\d
    /ix.freeze

    DATE_TIME_PATTERN = /
      \d{4}[\/\-年]\s*\d{1,2}[\/\-月]\s*\d{1,2}日?|\d{1,2}[:：]\d{2}|\d{1,2}時\d{1,2}分
    /x.freeze

    MONEY_OR_NUMERIC_PATTERN = /\A[\d\s\-\/:().,¥￥$€£%]+\z/.freeze
    DESCRIPTIVE_ONLY_HEADING_PATTERN = /
      \A(
        [\s&＆・\/\-]+|
        イタリアン|フレンチ|中華|和食|洋食|ワイン|カフェ|喫茶|レストラン|ダイニング|バー|グリル|
        restaurant|cafe|coffee|bar|grill|dining|wine|bistro|kitchen
      )+\z
    /ix.freeze
    LEGAL_ENTITY_DESIGNATOR_ONLY_PATTERN = /
      \A(
        株式会社|有限会社|合同会社|合名会社|合資会社|一般社団法人|一般財団法人|公益社団法人|公益財団法人|
        inc\.?|incorporated|ltd\.?|limited|llc|gmbh|ag|bv|nv|plc|corp\.?|corporation|company|
        co\.?\s*,?\s*ltd\.?|pty\s+ltd|pvt\.?\s+ltd|s\.?\s*a\.?|s\.?\s*a\.?\s*s\.?
      )\z
    /ix.freeze

    class << self
      def customer_facing_heading_candidates(lines, max_lines: 8)
        heading_lines = []

        Array(lines).first(max_lines).each do |line|
          text = normalize_name(line)
          next if text.blank?

          break if heading_lines.any? && heading_boundary_line?(text)
          next if heading_lines.empty? && heading_boundary_line?(text)
          next unless customer_facing_heading_line?(text)

          heading_lines << text
          break if heading_lines.size >= 3
        end

        candidates = []
        candidates << join_heading_lines(heading_lines) if heading_lines.size > 1
        candidates.concat(heading_lines)
        candidates.compact_blank.uniq
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
        normalize_name(text).to_s.match?(LEGAL_ENTITY_PATTERN)
      end

      def operator_context_line?(text)
        normalize_name(text).to_s.match?(OPERATOR_CONTEXT_PATTERN)
      end

      def descriptive_heading_line?(text)
        normalize_name(text).to_s.match?(DESCRIPTIVE_ONLY_HEADING_PATTERN)
      end

      def operator_legal_entity_candidate?(candidate, lines)
        normalized_candidate = normalize_name(candidate)
        return false unless legal_entity_name?(normalized_candidate)

        operator_context_near_candidate?(normalized_candidate, lines)
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

      def customer_facing_heading_line?(text)
        return false if text.length < 2
        return false if text.length > 60
        return false if legal_entity_name?(text)
        return false if operator_context_line?(text)
        return false if heading_boundary_line?(text)
        return false if descriptive_heading_line?(text)
        return false if text.match?(MONEY_OR_NUMERIC_PATTERN)

        text.match?(/[一-龠ぁ-んァ-ヶA-Za-z]/)
      end

      def heading_boundary_line?(text)
        normalized = normalize_name(text).to_s
        return true if normalized.match?(HEADING_STOP_PATTERN)
        return true if normalized.match?(ADDRESS_LIKE_PATTERN)
        return true if normalized.match?(DATE_TIME_PATTERN)
        return true if normalized.match?(/\bT\d{13}\b/i)

        false
      end

      def join_heading_lines(lines)
        compacted = Array(lines).map { |line| normalize_name(line) }.compact_blank
        return nil if compacted.blank?

        if compacted.any? { |line| japanese_text?(line) }
          compacted.join.gsub(/[[:space:]]+/, "")
        else
          compacted.join(" ").gsub(/[[:space:]]+/, " ")
        end
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
        normalize_name(text).to_s.match?(LEGAL_ENTITY_DESIGNATOR_ONLY_PATTERN)
      end

      def remove_legal_entity_designators(text)
        normalized = normalize_name(text).to_s
        brand = remove_japanese_legal_designators(normalized)
        brand = remove_english_legal_designators(brand)

        normalize_name(brand)
      end

      def remove_japanese_legal_designators(text)
        text
          .sub(/\A(?:株式会社|有限会社|合同会社|合名会社|合資会社|一般社団法人|一般財団法人|公益社団法人|公益財団法人)\s*/i, "")
          .sub(/\s*(?:株式会社|有限会社|合同会社|合名会社|合資会社|一般社団法人|一般財団法人|公益社団法人|公益財団法人)\z/i, "")
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
