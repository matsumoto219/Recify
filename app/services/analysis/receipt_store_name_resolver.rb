module Analysis
  class ReceiptStoreNameResolver
    FALLBACK_URL_OR_EMAIL_PATTERN = %r{https?://|www\.|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}}i
    STORE_CASING_CONTEXT_LINES_MAX_SETTING_KEY = "limits.store_name_casing_context_lines_max"
    STORE_CASING_CONTEXT_LINES_MAX = 12
    OPTIONS_SCHEMA_VERSION = "store_name_options_v1"
    OPTIONS_MAX = 100
    SOURCE_LINES_MAX = 1000
    STORE_NAME_MAX_LENGTH = 100

    class << self
      def call(**attributes)
        new.call(**attributes)
      end

      def options(ocr_result:, profile: nil)
        new(profile: profile || profile_for(ocr_result)).options(ocr_result: ocr_result)
      end

      def resolve(ocr_result:, ai_result: nil, profile: nil)
        new(profile: profile || profile_for(ocr_result)).resolve(ocr_result: ocr_result, ai_result: ai_result)
      end

      private

      def profile_for(ocr_result)
        source = ocr_result.is_a?(Hash) ? ocr_result : {}
        candidates = source[:candidates] || source["candidates"]
        country = candidates.is_a?(Hash) ? candidates[:country_region] || candidates["country_region"] : nil
        ReceiptAnalysisProfiles.fetch(country)
      end
    end

    def initialize(profile: ReceiptAnalysisProfiles.default)
      @profile = profile
    end

    def call(store_name:, lines:, case_preserved_lines:, ai_store_name: false, item_names: [])
      return store_name if store_name.blank?

      resolve(
        ocr_result: {
          candidates: { store_name: store_name, items: item_names.map { |name| { raw_text: name } } },
          lines: lines,
          case_preserved_lines: case_preserved_lines
        }
      )[:value]
    end

    def options(ocr_result:)
      return unavailable_options unless profile

      source = ocr_result.is_a?(Hash) ? ocr_result.deep_symbolize_keys : {}
      candidates = source[:candidates].is_a?(Hash) ? source[:candidates] : {}
      evidence = StoreNameEvidence.call(candidates[:store_name_evidence])
      unsupported_country = candidates[:country_region].present? && ReceiptAnalysisProfiles.fetch(candidates[:country_region]).nil?
      lines = bounded_lines(source[:lines])
      preserved = bounded_lines(source[:case_preserved_lines])
      item_names = Array(candidates[:items]).filter_map do |item|
        next unless item.is_a?(Hash)

        name = item[:raw_text].presence || item[:description].presence
        name if safe_store_text?(name)
      end
      entries = evidence ? evidence[:candidates] : legacy_entries(candidates, lines)
      entries = [] if evidence && evidence[:invalid] || unsupported_country
      available = entries.reject do |entry|
        entry[:span_state] == "invalid" || entry[:line_index].to_i >= SOURCE_LINES_MAX
      end
      return unavailable_options if duplicate_line_position?(available)

      composition_lines = evidence ? evidence_lines(available) : lines
      option_list = available.filter_map do |entry|
        option_for(entry, entries: available, lines: composition_lines, preserved: preserved, item_names: item_names)
      end.uniq { |option| compact_store_name(option[:value]) }
      truncated = evidence&.dig(:truncated) == true || option_list.length > OPTIONS_MAX
      option_list = option_list.first(OPTIONS_MAX)
      result = {
        schema_version: OPTIONS_SCHEMA_VERSION,
        options: option_list,
        truncated: truncated,
        invalid: evidence&.dig(:invalid) == true || unsupported_country
      }
      result[:checksum] = Digest::SHA256.hexdigest(JSON.generate(result))
      result
    end

    def resolve(ocr_result:, ai_result: nil)
      return missing_resolution unless profile

      source = ocr_result.is_a?(Hash) ? ocr_result.deep_symbolize_keys : {}
      candidates = source[:candidates].is_a?(Hash) ? source[:candidates] : {}
      source[:candidates] = candidates
      ai = ai_result.is_a?(Hash) ? ai_result.deep_symbolize_keys : {}
      ai[:receipt_attributes] = {} unless ai[:receipt_attributes].is_a?(Hash)
      option_set = options(ocr_result: source)
      meta = ai[:meta].is_a?(Hash) ? ai[:meta] : {}
      selection = StoreNameSelection.call(meta[:store_name_selection], options: option_set) if meta.key?(:store_name_selection)
      preferred = preferred_ocr_option(option_set, candidates)
      selected = if selection.nil? && compact_store_name(ai.dig(:receipt_attributes, :store_name)) == compact_store_name(store_name_value(candidates))
        preferred
      else
        selected_option(option_set, selection, ai)
      end
      selected ||= preferred
      return missing_resolution unless selected

      review_selection = selection
      if selection.nil? && legacy_ai_selects_option?(selected, ai, candidates)
        review_selection = { decision: "select" }
      end
      state = resolved_state(selected, option_set, review_selection)
      {
        value: selected[:value],
        state: state,
        option_id: selected[:option_id],
        reason_codes: resolution_review_reasons(state, source, ai, selection)
      }
    end

    private

    attr_reader :profile

    def unavailable_options
      result = { schema_version: OPTIONS_SCHEMA_VERSION, options: [], truncated: false, invalid: true }
      result.merge(checksum: Digest::SHA256.hexdigest(JSON.generate(result)))
    end

    def missing_resolution
      { value: nil, state: "missing", option_id: nil, reason_codes: [ "store_name_missing" ] }
    end

    def bounded_lines(value)
      Array(value).first(SOURCE_LINES_MAX).map do |line|
        next "" unless safe_store_text?(line)

        classifier.normalize_name(line).to_s
      end
    end

    def duplicate_line_position?(entries)
      indexes = entries.filter_map { |entry| entry[:line_index] if entry[:source] == "line" }
      indexes.uniq.length != indexes.length
    end

    def evidence_lines(entries)
      positioned = entries.select { |entry| entry[:line_index].is_a?(Integer) }
      lines = Array.new(positioned.map { |entry| entry[:line_index] }.max.to_i + 1, "")
      positioned.sort_by { |entry| entry[:source] == "line" ? 1 : 0 }.each do |entry|
        lines[entry[:line_index]] = classifier.normalize_name(entry[:text]).to_s
      end
      lines
    end

    def legacy_entries(candidates, lines)
      entries = []
      name = store_name_value(candidates)
      if safe_store_text?(name)
        entries << { candidate_id: "legacy_store", text: name, source: "legacy", span_state: "missing" }
      end
      lines.first(8).each_with_index do |line, index|
        entries << { candidate_id: "line_#{index}", text: line, source: "line", line_index: index, span_state: "missing" }
      end
      entries
    end

    def option_for(entry, entries:, lines:, preserved:, item_names:)
      original = entry[:text]
      item_names = [] if merchant_header_evidence?(entry, lines)
      return nil unless allowed_store_name?(original, item_names: item_names)

      composed = legal_brand_with_branch(original, lines) || resolve_store_name(original, lines, item_names: item_names)
      value = restore_store_name_casing(composed, preserved)
      return nil unless allowed_store_name?(value, item_names: item_names)

      supports = entries.select do |candidate|
        candidate.equal?(entry) || component_in_name?(candidate[:text], value)
      end
      candidate_ids = supports.map { |candidate| candidate[:candidate_id] }.uniq.sort
      kind = compact_store_name(value) == compact_store_name(original) ? "atomic" : "composed"
      {
        option_id: "store_option_#{Digest::SHA256.hexdigest([ kind, entry[:candidate_id], *candidate_ids ].join(':'))[0, 32]}",
        value: value,
        candidate_ids: candidate_ids,
        line_indexes: supports.filter_map { |candidate| candidate[:line_index] }.uniq.sort,
        source: entry[:source],
        confidence: kind == "atomic" ? entry[:confidence] : nil
      }.compact
    end

    def component_in_name?(component, name)
      normalized = compact_store_name(component)
      normalized.present? && compact_store_name(name).include?(normalized)
    end

    def legal_brand_with_branch(value, lines)
      brand = classifier.brand_candidate_from_legal_entity(value)
      return nil if brand.blank?

      index = lines.first(8).find_index { |line| compact_store_name(line) == compact_store_name(value) }
      return nil unless index

      branch = following_customer_facing_branch_line(lines.first(8), index)
      "#{brand} #{branch}" if branch
    end

    def merchant_header_evidence?(entry, lines)
      index = entry[:line_index]
      return false unless entry[:source] == "merchant_name" && entry[:span_state] == "exact" && entry[:confidence].to_f >= 0.9
      return false unless index.is_a?(Integer) && index.between?(0, 7)
      return false unless compact_store_name(lines[index]) == compact_store_name(entry[:text])

      lines.first(index).all? { |line| line.blank? || line.match?(profile.ocr_store_name_header_pattern) }
    end

    def allowed_store_name?(value, item_names:)
      return false unless safe_store_text?(value) && value.length <= STORE_NAME_MAX_LENGTH
      return false unless classifier.valid_candidate?(value, item_names: item_names)
      return false if store_name_context_noise_line?(value)
      return false if value.match?(FALLBACK_URL_OR_EMAIL_PATTERN)
      return false if value.match?(profile.ai_store_greeting_noise_pattern)
      return false if value.match?(/\A(?:#{profile.ocr_payment_method_pattern})\z/i)
      return false if value.match?(/\A(?:#{profile.ocr_settlement_line_pattern})\z/i)
      return false if classifier.operator_context_line?(value)
      return false if classifier.descriptive_heading_line?(value)
      return false if classifier.isolated_logo_fragment?(value)

      true
    end

    def selected_option(option_set, selection, ai)
      if selection
        return nil unless selection[:decision] == "select"

        return option_set[:options].find { |option| option[:option_id] == selection[:option_id] }
      end

      ai_name = ai.dig(:receipt_attributes, :store_name)
      return nil unless safe_store_text?(ai_name)

      option_set[:options].find { |option| compact_store_name(option[:value]) == compact_store_name(ai_name) }
    end

    def legacy_ai_selects_option?(selected, ai, candidates)
      ai_name = ai.dig(:receipt_attributes, :store_name)
      return false unless safe_store_text?(ai_name)
      return true if compact_store_name(ai_name) == compact_store_name(selected[:value])

      selected[:candidate_ids].include?("legacy_store") &&
        compact_store_name(ai_name) == compact_store_name(store_name_value(candidates))
    end

    def preferred_ocr_option(option_set, candidates)
      printed = complete_printed_options(option_set, store_name_value(candidates))
      return printed.first if printed.one?

      preferred = option_set[:options].find do |option|
        compact_store_name(option[:value]) == compact_store_name(store_name_value(candidates)) ||
          option[:candidate_ids].include?("legacy_store")
      end
      preferred || option_set[:options].first
    end

    def complete_printed_options(option_set, store_name)
      return [] unless safe_store_text?(store_name)

      normalized = classifier.normalize_name(store_name)
      return [] if normalized.blank?

      option_set[:options].select do |option|
        prefix_length = normalized.length + 1
        next false unless option[:value][0, prefix_length].casecmp?("#{normalized} ")

        suffix = option[:value][prefix_length..]

        customer_facing_branch_candidate(suffix) == suffix
      end
    end

    def resolved_state(selected, option_set, selection)
      return "uncertain" if option_set[:invalid]
      return "uncertain" if selection && %w[ambiguous reject].include?(selection[:decision])
      return "uncertain" if classifier.legal_entity_name?(selected[:value])
      return "uncertain" if selection&.dig(:decision) != "select" && conflicting_options?(selected, option_set)
      return "confirmed" if selected[:source] == "merchant_name" && selected[:confidence].to_f >= 0.9
      return "uncertain" if option_set[:truncated]
      return "confirmed" if selected[:line_indexes].any?
      return "confirmed" if selected[:source] == "merchant_name" && selected[:confidence].to_f >= 0.75

      "uncertain"
    end

    def conflicting_options?(selected, option_set)
      option_set[:options].any? do |option|
        next false if option[:option_id] == selected[:option_id]
        !component_in_name?(option[:value], selected[:value]) && !component_in_name?(selected[:value], option[:value])
      end
    end

    def store_name_value(candidates)
      value = candidates[:store_name]
      value.is_a?(Hash) ? value[:value] : value
    end

    def resolution_review_reasons(state, source, ai, selection)
      return [] if state == "confirmed"
      return [ "store_name_uncertain" ] if source.dig(:candidates, :store_name_evidence).present? || selection

      prior_reasons = Array(ai[:review_reasons]) + Array(source.dig(:candidates, :review_reasons))
      prior_reasons.intersect?(%w[store_name_missing store_name_uncertain]) ? [ "store_name_uncertain" ] : []
    end

    def resolve_store_name(store_name, lines, item_names: [])
      normalized_store_name = compact_store_name(store_name)
      return store_name if normalized_store_name.blank?
      return nil unless classifier.valid_candidate?(store_name, item_names: item_names)

      local_complete_replacement = local_complete_store_name_replacement(store_name, lines)
      return local_complete_replacement if local_complete_replacement.present?

      latin_logo_extension = latin_logo_local_store_name_extension(store_name, lines)
      return latin_logo_extension if latin_logo_extension.present?

      printed_extension = printed_store_name_extension(store_name, lines)
      return printed_extension if printed_extension.present?

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
      @store_casing_context_lines_max ||= SystemSettings.limit_for(STORE_CASING_CONTEXT_LINES_MAX_SETTING_KEY)
    rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
      STORE_CASING_CONTEXT_LINES_MAX
    end

    def store_name_casing_candidate(line)
      candidate = classifier.normalize_name(line)
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

    def store_name_has_location_marker?(store_name)
      store_name.to_s.match?(profile.store_location_marker_pattern)
    end

    def local_complete_store_name_replacement(store_name, lines)
      header_lines = Array(lines).first(8).map do |line|
        classifier.normalize_name(line).to_s
      end

      header_lines.find do |line|
        customer_facing_store_line?(line) &&
          classifier.latin_logo_prefix_duplicate?(store_name, line)
      end
    end

    def latin_logo_local_store_name_extension(store_name, lines)
      current_store_name = compact_store_name(store_name)
      return nil if current_store_name.blank?

      header_lines = Array(lines).first(8).map do |line|
        classifier.normalize_name(line).to_s
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

      printed_branch = classifier.normalize_name(branch_line)
      return nil unless current_store_name.include?(compact_store_name(printed_branch))

      brand = canonical_latin_logo_brand(logo_line, lines)
      descriptor = normalize_local_business_descriptor(descriptor_line)
      branch = printed_branch
      return nil if brand.blank? || descriptor.blank? || branch.blank?

      "#{brand} #{descriptor} #{branch}"
    end

    def printed_store_name_extension(store_name, lines)
      normalized_store_name = compact_store_name(store_name)
      header_lines = Array(lines).first(8).map do |line|
        classifier.normalize_name(line).to_s
      end
      return nil if header_lines.blank?

      store_index = header_lines.find_index { |line| compact_store_name(line) == normalized_store_name }
      return nil if store_index.nil?

      branch_line = following_customer_facing_branch_line(header_lines, store_index)

      if store_name_needs_preceding_brand?(store_name)
        brand_entry = header_lines[0...store_index]&.each_with_index&.to_a&.reverse&.find do |line, index|
          customer_facing_brand_line?(line, header_lines:, line_index: index)
        end
        brand_line = brand_entry&.first
        if brand_line.present? && (store_name_has_location_marker?(store_name) || store_brand_type_line?(brand_line))
          base_name = "#{brand_line} #{classifier.normalize_name(store_name)}"
          return [ base_name, branch_line ].compact.join(" ")
        end
      end

      return nil if branch_line.blank?

      "#{classifier.normalize_name(store_name)} #{branch_line}"
    end

    def legal_entity_brand_store_name_extension(store_name, lines)
      current_store_name = compact_store_name(store_name)
      header_lines = Array(lines).first(8).map do |line|
        classifier.normalize_name(line).to_s
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
        brand = classifier.brand_candidate_from_legal_entity(line)
        next if brand.blank?

        branch = following_customer_facing_branch_line(header_lines, index)
        next if branch.blank?

        { brand: brand, branch: branch }
      end
    end

    def customer_facing_store_line?(line)
      normalized = line.to_s
      return false if store_name_context_noise_line?(normalized)
      return false if classifier.legal_entity_name?(normalized)
      return false if classifier.descriptive_heading_line?(normalized)

      normalized.match?(profile.store_name_letter_pattern)
    end

    def customer_facing_branch_line?(line)
      normalized = line.to_s
      return false unless customer_facing_store_line?(normalized)
      return false if normalized.match?(profile.store_legal_entity_branch_exclusion_pattern)
      return false if store_brand_type_line?(normalized)
      return false if building_or_floor_line?(normalized)
      return false if normalized.match?(/[¥￥円$€£]/)
      return false if normalized.match?(/\d{2,}/)
      return false if normalized.match?(profile.store_operator_number_noise_pattern)

      normalized.length <= 30
    end

    def following_customer_facing_branch_line(header_lines, base_index)
      Array(header_lines)[(base_index + 1)..(base_index + 3)].to_a.each do |line|
        candidate = customer_facing_branch_candidate(line)
        return candidate if candidate
        break if line.blank? || line.match?(profile.store_heading_stop_pattern) || line.match?(profile.store_date_time_pattern)
      end
      nil
    end

    def customer_facing_branch_candidate(line)
      candidate = store_branch_candidate_line(line)
      return nil if candidate.blank?
      return nil unless store_name_has_location_marker?(candidate)

      customer_facing_branch_line?(candidate) ? candidate : nil
    end

    def store_branch_candidate_line(line)
      normalized = classifier.normalize_name(line).to_s
      normalized = normalized.sub(profile.store_branch_phone_suffix_pattern, "")
      normalized.strip.presence
    end

    def store_name_needs_preceding_brand?(store_name)
      normalized = classifier.normalize_name(store_name).to_s
      return false if classifier.complete_local_store_name?(normalized)
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
      normalized = classifier.normalize_name(line).to_s
      return false unless customer_facing_brand_line?(normalized, header_lines:, line_index:)
      return false if normalized.match?(profile.store_local_script_pattern)
      return false if normalized.match?(/\s/)

      normalized.match?(/\A[A-Za-z][A-Za-z0-9&.'-]{1,30}\z/)
    end

    def local_business_descriptor_line?(line)
      normalized = classifier.normalize_name(line).to_s
      return false unless normalized.match?(profile.store_local_script_pattern)
      return false if customer_facing_branch_line?(normalized)
      return false if store_name_context_noise_line?(normalized)

      normalized.match?(profile.store_local_business_descriptor_pattern)
    end

    def normalize_local_business_descriptor(line)
      normalized = classifier.normalize_name(line).to_s
      parts = normalized.split
      if parts.size > 1
        remainder = parts[1..].join(" ")
        normalized = remainder if parts.first.match?(profile.store_local_descriptor_prefix_pattern) && local_business_descriptor_line?(remainder)
      end

      normalized.match?(profile.store_local_script_pattern) ? normalized.gsub(/[[:space:]]+/, "") : normalized
    end

    def canonical_latin_logo_brand(line, lines)
      normalized = classifier.normalize_name(line).to_s
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
      return false unless classifier.isolated_logo_fragment?(line)
      return false if line_index.nil?

      Array(header_lines)[(line_index + 1)..].to_a.any? do |candidate|
        customer_facing_store_line?(candidate) &&
          !classifier.isolated_logo_fragment?(candidate)
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
      return true if classifier.store_message_line?(normalized)
      return true if compact.match?(profile.store_context_compact_noise_pattern)
      return true if building_or_floor_line?(normalized)
      return true if normalized.match?(profile.store_context_noise_pattern)
      return true if normalized.match?(profile.ai_store_system_noise_pattern)
      return true if normalized.match?(profile.store_date_time_pattern)
      return true if normalized.match?(profile.store_context_address_pattern)
      return true if normalized.match?(profile.store_context_receipt_noise_pattern)

      false
    end

    def compact_store_name(value)
      return "" unless safe_store_text?(value)

      classifier.normalize_compact_name(value).to_s.downcase
    end

    def safe_store_text?(value)
      value.is_a?(String) && value.valid_encoding? &&
        (value.encoding == Encoding::UTF_8 || value.ascii_only?) &&
        value.bytesize <= 500 && !value.match?(/[\u0000-\u001F\u007F]/)
    end

    def classifier
      @classifier ||= StoreNameCandidateClassifier.new(profile: profile)
    end
  end
end
