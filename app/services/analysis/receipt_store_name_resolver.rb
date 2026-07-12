module Analysis
  class ReceiptStoreNameResolver
    FALLBACK_URL_OR_EMAIL_PATTERN = %r{https?://|www\.|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}}i
    STORE_CASING_CONTEXT_LINES_MAX_SETTING_KEY = "limits.store_name_casing_context_lines_max"
    STORE_CASING_CONTEXT_LINES_MAX = 12

    class << self
      def call(store_name:, lines:, case_preserved_lines:, ai_store_name: false, item_names: [])
        resolved_store_name = resolve_store_name(
          store_name,
          lines,
          ai_store_name: ai_store_name,
          item_names: item_names
        )

        restore_store_name_casing(resolved_store_name, case_preserved_lines)
      end

      private

      def resolve_store_name(store_name, lines, ai_store_name: false, item_names: [])
        normalized_store_name = compact_store_name(store_name)
        return store_name if normalized_store_name.blank?
        return nil unless Analysis.store_name_candidate_valid?(store_name, item_names: item_names)

        local_complete_replacement = local_complete_store_name_replacement(store_name, lines)
        return local_complete_replacement if local_complete_replacement.present?

        latin_logo_extension = latin_logo_local_store_name_extension(store_name, lines)
        return latin_logo_extension if latin_logo_extension.present?

        printed_extension = printed_store_name_extension(store_name, lines)
        return printed_extension if printed_extension.present?

        if ai_store_name && complete_customer_facing_ai_store_name?(store_name, lines)
          return Analysis::StoreNameCandidateClassifier.normalize_name(store_name)
        end

        legal_entity_extension = legal_entity_brand_store_name_extension(store_name, lines)
        return legal_entity_extension if legal_entity_extension.present?

        store_name
      end

      def restore_store_name_casing(store_name, case_preserved_lines)
        restored = store_name.to_s
        return store_name if restored.blank?

        store_name_casing_candidates(case_preserved_lines).each do |candidate|
          restored = restore_store_name_casing_candidate(restored, candidate)
        end

        restored
      end

      def store_name_casing_candidates(case_preserved_lines)
        Array(case_preserved_lines)
          .first(store_casing_context_lines_max)
          .filter_map { |line| store_name_casing_candidate(line) }
          .uniq
          .sort_by { |candidate| -candidate.length }
      end

      def store_casing_context_lines_max
        SystemSettings.limit_for(STORE_CASING_CONTEXT_LINES_MAX_SETTING_KEY)
      rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
        STORE_CASING_CONTEXT_LINES_MAX
      end

      def store_name_casing_candidate(line)
        candidate = Analysis.normalize_store_name_candidate(line)
        return nil if candidate.blank?
        return nil unless candidate.match?(/[A-Za-z]/)
        return nil if candidate.match?(FALLBACK_URL_OR_EMAIL_PATTERN)
        return nil if candidate.match?(/\A[A-Za-z]{1,4}\z/)
        return nil if store_name_context_noise_line?(candidate)

        candidate
      end

      def restore_store_name_casing_candidate(store_name, candidate)
        pattern = Regexp.new(Regexp.escape(candidate), Regexp::IGNORECASE)
        return store_name unless store_name.match?(pattern)

        store_name.gsub(pattern, candidate)
      end

      def complete_customer_facing_ai_store_name?(store_name, lines)
        normalized = Analysis::StoreNameCandidateClassifier.normalize_name(store_name).to_s
        return false if normalized.blank?
        return false unless customer_facing_store_line?(normalized)
        return false if Analysis::StoreNameCandidateClassifier.isolated_logo_fragment?(normalized)
        return false if normalized.split.any? { |part| Analysis::StoreNameCandidateClassifier.isolated_logo_fragment?(part) }
        return false if store_name_needs_preceding_brand?(normalized)
        return false if store_name_has_following_branch_candidate?(normalized, lines)

        store_name_supported_by_header?(normalized, lines)
      end

      def store_name_supported_by_header?(store_name, lines)
        normalized_store_name = compact_store_name(store_name)
        header_lines = Array(lines).first(8).filter_map do |line|
          Analysis::StoreNameCandidateClassifier.normalize_name(line)
        end

        header_lines.any? { |line| compact_store_name(line) == normalized_store_name } ||
          Analysis::StoreNameCandidateClassifier.customer_facing_heading_candidates(header_lines).any? do |candidate|
            compact_store_name(candidate) == normalized_store_name
          end
      end

      def store_name_has_following_branch_candidate?(store_name, lines)
        return false if store_name_has_location_marker?(store_name)

        normalized_store_name = compact_store_name(store_name)
        header_lines = Array(lines).first(8).filter_map do |line|
          Analysis::StoreNameCandidateClassifier.normalize_name(line)
        end
        store_index = header_lines.find_index { |line| compact_store_name(line) == normalized_store_name }
        return false if store_index.nil?

        header_lines[(store_index + 1)..(store_index + 3)]&.any? do |line|
          customer_facing_branch_candidate(line).present?
        end
      end

      def store_name_has_location_marker?(store_name)
        store_name.to_s.match?(profile.store_location_marker_pattern)
      end

      def local_complete_store_name_replacement(store_name, lines)
        header_lines = Array(lines).first(8).filter_map do |line|
          Analysis::StoreNameCandidateClassifier.normalize_name(line)
        end

        header_lines.find do |line|
          customer_facing_store_line?(line) &&
            Analysis::StoreNameCandidateClassifier.latin_logo_prefix_duplicate?(store_name, line)
        end
      end

      def latin_logo_local_store_name_extension(store_name, lines)
        current_store_name = compact_store_name(store_name)
        return nil if current_store_name.blank?

        header_lines = Array(lines).first(8).filter_map do |line|
          Analysis::StoreNameCandidateClassifier.normalize_name(line)
        end
        return nil if header_lines.blank?

        logo_entry = header_lines.each_with_index.find do |line, index|
          latin_logo_store_brand_line?(line, header_lines:, line_index: index)
        end
        return nil if logo_entry.blank?

        logo_line, logo_index = logo_entry
        descriptor_entry = header_lines[(logo_index + 1)..]&.each_with_index&.find do |line, _relative_index|
          local_business_descriptor_line?(line)
        end
        return nil if descriptor_entry.blank?

        descriptor_line, descriptor_relative_index = descriptor_entry
        descriptor_index = logo_index + 1 + descriptor_relative_index
        branch_line = following_customer_facing_branch_line(header_lines, descriptor_index)
        return nil if branch_line.blank?

        printed_branch = Analysis::StoreNameCandidateClassifier.normalize_name(branch_line)
        return nil unless current_store_name.include?(compact_store_name(printed_branch))

        brand = canonical_latin_logo_brand(logo_line, lines)
        descriptor = normalize_local_business_descriptor(descriptor_line)
        branch = printed_branch
        return nil if brand.blank? || descriptor.blank? || branch.blank?

        "#{brand} #{descriptor} #{branch}"
      end

      def printed_store_name_extension(store_name, lines)
        normalized_store_name = compact_store_name(store_name)
        header_lines = Array(lines).first(8).filter_map do |line|
          Analysis::StoreNameCandidateClassifier.normalize_name(line)
        end
        return nil if header_lines.blank?

        containing_line = header_lines.find do |line|
          normalized_line = compact_store_name(line)
          normalized_line != normalized_store_name && normalized_line.include?(normalized_store_name)
        end
        return containing_line if containing_line.present? && customer_facing_store_line?(containing_line)

        store_index = header_lines.find_index { |line| compact_store_name(line) == normalized_store_name }
        return nil if store_index.nil?

        branch_line = following_customer_facing_branch_line(header_lines, store_index)

        if store_name_needs_preceding_brand?(store_name)
          brand_entry = header_lines[0...store_index]&.each_with_index&.to_a&.reverse&.find do |line, index|
            customer_facing_brand_line?(line, header_lines:, line_index: index)
          end
          brand_line = brand_entry&.first
          if brand_line.present?
            base_name = "#{brand_line} #{Analysis::StoreNameCandidateClassifier.normalize_name(store_name)}"
            return [ base_name, branch_line ].compact.join(" ")
          end
        end

        return nil if branch_line.blank?

        "#{Analysis::StoreNameCandidateClassifier.normalize_name(store_name)} #{branch_line}"
      end

      def legal_entity_brand_store_name_extension(store_name, lines)
        current_store_name = compact_store_name(store_name)
        header_lines = Array(lines).first(8).filter_map do |line|
          Analysis::StoreNameCandidateClassifier.normalize_name(line)
        end
        return nil if header_lines.blank?

        current_store_name_in_header = header_lines.any? do |line|
          compact_store_name(line) == current_store_name
        end

        legal_entity_brand_branch_pairs(header_lines).each do |pair|
          brand = pair[:brand]
          branch = pair[:branch]
          compact_brand = compact_store_name(brand)
          compact_branch = compact_store_name(branch)
          next if compact_brand.blank? || compact_branch.blank?
          next if current_store_name.include?(compact_brand)
          next unless current_store_name.include?(compact_branch) || current_store_name_in_header

          return "#{brand} #{branch}"
        end

        nil
      end

      def legal_entity_brand_branch_pairs(header_lines)
        Array(header_lines).each_with_index.filter_map do |line, index|
          brand = Analysis::StoreNameCandidateClassifier.brand_candidate_from_legal_entity(line)
          next if brand.blank?

          branch = following_customer_facing_branch_line(header_lines, index)
          next if branch.blank?

          { brand: brand, branch: branch }
        end
      end

      def customer_facing_store_line?(line)
        normalized = line.to_s
        return false if store_name_context_noise_line?(normalized)
        return false if Analysis::StoreNameCandidateClassifier.legal_entity_name?(normalized)
        return false if Analysis::StoreNameCandidateClassifier.descriptive_heading_line?(normalized)

        normalized.match?(/[一-龠ぁ-んァ-ヶA-Za-z]/)
      end

      def customer_facing_branch_line?(line)
        normalized = line.to_s
        return false unless customer_facing_store_line?(normalized)
        return false if normalized.match?(profile.store_legal_entity_branch_exclusion_pattern)
        return false if store_brand_type_line?(normalized)
        return false if building_or_floor_line?(normalized)
        return false if normalized.match?(/[¥￥円$€£]/)
        return false if normalized.match?(/\d{2,}/)
        return false if normalized.match?(/\A\d+[[:alpha:]一-龠ぁ-んァ-ヶ]{0,2}\z/)

        normalized.length <= 30
      end

      def following_customer_facing_branch_line(header_lines, base_index)
        Array(header_lines)[(base_index + 1)..(base_index + 3)]&.filter_map do |line|
          customer_facing_branch_candidate(line)
        end&.first
      end

      def customer_facing_branch_candidate(line)
        candidate = store_branch_candidate_line(line)
        return nil if candidate.blank?
        return nil unless store_name_has_location_marker?(candidate)

        customer_facing_branch_line?(candidate) ? candidate : nil
      end

      def store_branch_candidate_line(line)
        normalized = Analysis::StoreNameCandidateClassifier.normalize_name(line).to_s
        normalized = normalized.sub(profile.store_branch_phone_suffix_pattern, "")
        normalized.strip.presence
      end

      def store_name_needs_preceding_brand?(store_name)
        normalized = Analysis::StoreNameCandidateClassifier.normalize_name(store_name).to_s
        return false if Analysis::StoreNameCandidateClassifier.complete_local_store_name?(normalized)
        return false if store_brand_type_line?(normalized)

        customer_facing_branch_line?(normalized)
      end

      def customer_facing_brand_line?(line, header_lines: [], line_index: nil)
        normalized = line.to_s
        return false unless customer_facing_store_line?(normalized)
        return false if isolated_logo_fragment_prefix?(normalized, header_lines:, line_index:)
        return false if normalized.match?(profile.store_location_marker_pattern)
        return false if normalized.match?(/[¥￥円$€£]/)

        normalized.length <= 40
      end

      def latin_logo_store_brand_line?(line, header_lines: [], line_index: nil)
        normalized = Analysis::StoreNameCandidateClassifier.normalize_name(line).to_s
        return false unless customer_facing_brand_line?(normalized, header_lines:, line_index:)
        return false if normalized.match?(/[一-龠ぁ-んァ-ヶ]/)
        return false if normalized.match?(/\s/)

        normalized.match?(/\A[A-Za-z][A-Za-z0-9&.'-]{1,30}\z/)
      end

      def local_business_descriptor_line?(line)
        normalized = Analysis::StoreNameCandidateClassifier.normalize_name(line).to_s
        return false unless normalized.match?(/[一-龠ぁ-んァ-ヶ]/)
        return false if customer_facing_branch_line?(normalized)
        return false if store_name_context_noise_line?(normalized)

        normalized.match?(profile.store_local_business_descriptor_pattern)
      end

      def normalize_local_business_descriptor(line)
        normalized = Analysis::StoreNameCandidateClassifier.normalize_name(line).to_s
        parts = normalized.split
        if parts.size > 1
          remainder = parts[1..].join(" ")
          normalized = remainder if parts.first.match?(/\A[ァ-ヶー]{2,8}\z/) && local_business_descriptor_line?(remainder)
        end

        normalized.match?(/[一-龠ぁ-んァ-ヶ]/) ? normalized.gsub(/[[:space:]]+/, "") : normalized
      end

      def canonical_latin_logo_brand(line, lines)
        normalized = Analysis::StoreNameCandidateClassifier.normalize_name(line).to_s
        compact = normalized.gsub(/[^A-Za-z0-9&.'-]/, "")
        candidate = domain_brand_tokens(lines).find do |token|
          latin_brand_token_match?(compact.downcase, token)
        end

        format_latin_brand_name(candidate || compact)
      end

      def domain_brand_tokens(lines)
        Array(lines).flat_map do |line|
          line.to_s.downcase.scan(%r{(?:https?://)?(?:www\.)?([a-z0-9][a-z0-9-]{2,30})\.(?:co\.jp|jp|com|net|store|shop)\b}).flatten
        end.uniq
      end

      def latin_brand_token_match?(brand, token)
        return false if brand.blank? || token.blank?
        return true if brand == token
        return true if brand.start_with?(token) && (brand.length - token.length) <= 2
        return true if token.start_with?(brand) && (token.length - brand.length) <= 2

        false
      end

      def format_latin_brand_name(value)
        text = value.to_s.strip
        return nil if text.blank?
        return text if text.match?(/[A-Z]/)

        text[0].upcase + text[1..].to_s
      end

      def isolated_logo_fragment_prefix?(line, header_lines:, line_index:)
        return false unless Analysis::StoreNameCandidateClassifier.isolated_logo_fragment?(line)
        return false if line_index.nil?

        Array(header_lines)[(line_index + 1)..].to_a.any? do |candidate|
          customer_facing_store_line?(candidate) &&
            !Analysis::StoreNameCandidateClassifier.isolated_logo_fragment?(candidate)
        end
      end

      def store_brand_type_line?(line)
        line.to_s.match?(profile.store_brand_type_pattern)
      end

      def building_or_floor_line?(line)
        line.to_s.match?(profile.store_building_or_floor_pattern)
      end

      def store_name_context_noise_line?(line)
        normalized = line.to_s
        compact = normalized.gsub(/[[:space:]]+/, "")
        return true if Analysis::StoreNameCandidateClassifier.store_message_line?(normalized)
        return true if compact.match?(profile.store_context_compact_noise_pattern)
        return true if building_or_floor_line?(normalized)
        return true if normalized.match?(profile.store_context_noise_pattern)
        return true if normalized.match?(/tax\s*(?:id|number)|vat\s*(?:id|number)|register|receipt|invoice|customer\s+service|support/i)
        return true if normalized.match?(/\d{4}[\/\-年]\s*\d{1,2}[\/\-月]\s*\d{1,2}日?/)
        return true if normalized.match?(profile.store_context_address_pattern)
        return true if normalized.match?(profile.store_context_receipt_noise_pattern)

        false
      end

      def compact_store_name(value)
        Analysis::StoreNameCandidateClassifier.normalize_compact_name(value).to_s.downcase
      end

      def profile
        ReceiptAnalysisProfiles.default
      end
    end
  end
end
