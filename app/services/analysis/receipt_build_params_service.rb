module Analysis
  class ReceiptBuildParamsService
    TAX_RATE_CONFIDENCE_WARNING_THRESHOLD = BigDecimal("0.75")
    PARENTHESIZED_PAYMENT_CODE_PATTERN = /[（(]\s*\d{1,6}\s*[)）]/
    FALLBACK_URL_OR_EMAIL_PATTERN = %r{https?://|www\.|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}}i
    OCR_ADJUSTMENT_FALLBACK_CONFIDENCE_THRESHOLD = BigDecimal("0.75")
    PAYMENT_METHOD_REPRESENTATIVE_PRIORITY = %w[credit_card cash e_money qr_payment debit_card].freeze
    ADJUSTMENT_UNCERTAIN_REVIEW_REASON = "adjustment_uncertain"
    STORE_CASING_CONTEXT_LINES_MAX_SETTING_KEY = "limits.store_name_casing_context_lines_max"
    STORE_CASING_CONTEXT_LINES_MAX = 12

    class << self
      def call(ocr_result:, ai_result: nil)
        normalized_ocr_result = normalize_ocr_result(ocr_result)
        candidates = normalize_candidates(normalized_ocr_result)
        lines = normalized_lines(normalized_ocr_result)
        case_preserved_lines = normalized_case_preserved_lines(normalized_ocr_result)
        normalized_ai_result = normalize_ai_result(ai_result)
        skipped_negative_items = []
        ai_receipt_attributes = normalized_ai_result[:receipt_attributes]
        receipt_attributes = build_receipt_attributes(candidates, ai_receipt_attributes, lines, case_preserved_lines)
        receipt_items_attributes = build_receipt_items_attributes(
          candidates,
          lines,
          normalized_ai_result[:receipt_items_attributes],
          ai_name_completion_enabled: normalized_ai_result.dig(:meta, :ai_name_completion_enabled),
          skipped_negative_items:
        )
        receipt_payments_attributes = build_receipt_payments_attributes(
          candidates,
          lines,
          receipt_total: receipt_attributes[:total_amount]
        )
        receipt_tax_details_attributes = recover_receipt_tax_details_from_lines(
          build_receipt_tax_details_attributes(candidates),
          lines,
          receipt_attributes
        )
        source_evidence_index = SourceEvidenceIndex.call(
          lines: lines,
          money_pattern: profile.analysis_adjustment_amount_candidate_pattern,
          profile: profile
        )
        invalid_adjustment_review_reasons = []
        receipt_adjustments_attributes = build_receipt_adjustments_attributes(
          normalized_ai_result[:receipt_adjustments_attributes],
          candidates[:adjustment_candidates],
          lines,
          receipt_items_attributes,
          skipped_negative_items,
          receipt_payments_attributes,
          receipt_tax_details_attributes,
          source_evidence_index,
          invalid_review_reasons: invalid_adjustment_review_reasons
        )
        ownership_result = ReceiptFactOwnershipResolver.call(
          items: receipt_items_attributes,
          adjustments: receipt_adjustments_attributes,
          payments: receipt_payments_attributes,
          tax_details: receipt_tax_details_attributes,
          review_reasons: invalid_adjustment_review_reasons,
          evidence_index: source_evidence_index,
          profile: profile
        )
        receipt_items_attributes = ownership_result.items
        receipt_adjustments_attributes = ownership_result.adjustments
        receipt_payments_attributes = ownership_result.payments
        receipt_tax_details_attributes = ownership_result.tax_details
        invalid_adjustment_review_reasons = ownership_result.review_reasons
        receipt_payments_attributes = add_cash_difference_payment(
          receipt_payments_attributes,
          lines,
          receipt_attributes[:total_amount]
        )
        receipt_attributes[:payment_method] = reconcile_payment_method_with_payments(
          receipt_attributes[:payment_method],
          receipt_payments_attributes,
          adjustments: receipt_adjustments_attributes,
          lines:,
          receipt_total: receipt_attributes[:total_amount]
        )
        amount_hints = build_amount_hints(
          ai_receipt_attributes,
          candidates,
          lines,
          receipt_attributes
        )

        tax_rate_correction = apply_tax_detail_amount_match_policy(
          receipt_items_attributes,
          receipt_adjustments_attributes,
          receipt_tax_details_attributes
        ) || apply_tax_marker_group_amount_match_policy(
          receipt_items_attributes,
          receipt_tax_details_attributes,
          lines
        ) || apply_single_tax_detail_rate_policy(
          receipt_items_attributes,
          receipt_adjustments_attributes,
          receipt_tax_details_attributes,
          receipt_attributes
        )
        tax_allocation_result = TaxAllocationResolver.call(
          ownership_result: ownership_result,
          items: receipt_items_attributes,
          adjustments: receipt_adjustments_attributes,
          tax_details: receipt_tax_details_attributes,
          tax_rate_correction: tax_rate_correction
        )
        receipt_adjustments_attributes = tax_allocation_result.adjustments
        invalid_adjustment_review_reasons = tax_allocation_result.review_reasons
        ownership_contract = OwnershipConsistencyGuard.contract_for(tax_allocation_result)
        review_reasons = (
          skipped_negative_adjustment_review_reasons(skipped_negative_items, receipt_adjustments_attributes) +
          invalid_adjustment_review_reasons
        ).uniq
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
          amount_hints: amount_hints,
          tax_rate_correction: tax_rate_correction,
          ownership_contract: ownership_contract,
          corrections: corrections
        }
      end

      private

      def profile
        ReceiptAnalysisProfiles.default
      end

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

      def normalized_case_preserved_lines(ocr_result)
        Array(ocr_result[:case_preserved_lines]).filter_map do |line|
          Analysis.normalize_store_name_candidate(line)
        end
      end

      def normalize_ai_result(ai_result)
        return { receipt_attributes: {}, receipt_items_attributes: [], receipt_adjustments_attributes: [] } unless ai_result.is_a?(Hash)

        symbolized = ai_result.deep_symbolize_keys

        # AI item は保存用完全データではなく、index ベースの補完データを受ける前提。
        # 主に suggested_name / category / needs_review を OCR item にマージするための中間形式として扱う。

        {
          receipt_attributes: symbolized[:receipt_attributes] || {},
          receipt_items_attributes: Array(symbolized[:receipt_items_attributes]),
          receipt_adjustments_attributes: Array(symbolized[:receipt_adjustments_attributes]),
          meta: symbolized[:meta] || {}
        }
      end

      def build_receipt_attributes(candidates, ai_receipt_attributes, lines, case_preserved_lines)
        ai_attrs = normalize_receipt_attributes(ai_receipt_attributes)
        ai_store_name = ai_attrs[:store_name].presence
        store_name = resolve_store_name(
          ai_store_name || candidates[:store_name],
          lines,
          ai_store_name: ai_store_name.present?
        )
        store_name = restore_store_name_casing(store_name, case_preserved_lines)

        {
          store_name: store_name,
          store_address: ai_attrs[:store_address].presence || candidates[:store_address],           # 実レシートでは未取得が多いが、取得値は住所として表示/編集対象にする
          store_address_components: normalize_store_address_components(
            ai_attrs[:store_address_components].presence || candidates[:store_address_components]
          ),
          store_phone_number: ai_attrs[:store_phone_number].presence || candidates[:store_phone_number],
          purchased_at: parse_purchased_at_with_time_fallback(ai_attrs, candidates, lines),
          total_amount: resolve_receipt_total_amount(ai_attrs, candidates, lines),
          subtotal_amount: ai_attrs[:subtotal_amount] || normalize_amount(candidates[:subtotal_amount]),
          tax_amount: resolve_receipt_tax_amount(ai_attrs, candidates, lines),
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

      def resolve_receipt_total_amount(ai_attrs, candidates, lines)
        preferred_total = normalize_amount(ai_attrs[:total_amount]) || normalize_amount(candidates[:total_amount])
        inferred_total = tax_section_gross_total_from_lines(lines)
        if inferred_total&.positive? && low_quality_receipt_total_candidate?(preferred_total, inferred_total)
          return inferred_total
        end

        settlement_total = settlement_purchase_total_from_lines(lines)
        return preferred_total if preferred_total.blank?
        return preferred_total unless settlement_total&.positive?

        deposit_amount = settlement_amount_from_lines(lines, profile.analysis_cash_deposit_label_pattern)
        return settlement_total if deposit_amount&.positive? && preferred_total.to_i == deposit_amount

        preferred_total
      end

      def resolve_receipt_tax_amount(ai_attrs, candidates, lines)
        ai_tax = normalize_amount(ai_attrs[:tax_amount])
        return ai_tax if ai_tax.present?

        line_tax = tax_total_amount_from_lines(lines)
        candidate_tax = normalize_amount(candidates[:tax_amount])
        return line_tax if line_tax&.positive? && (candidate_tax.blank? || line_tax.to_i >= candidate_tax.to_i)

        candidate_tax
      end

      def low_quality_receipt_total_candidate?(preferred_total, inferred_total)
        return true if preferred_total.blank?
        return false unless inferred_total&.positive?

        preferred_total.to_i < inferred_total.to_i / 2
      end

      def build_amount_hints(ai_receipt_attributes, candidates, lines, receipt_attributes)
        return {} unless settlement_receipt_total_restored?(ai_receipt_attributes, candidates, lines, receipt_attributes)

        {
          settlement_total_from_deposit_change: true,
          settlement_total: receipt_attributes[:total_amount]
        }
      end

      def settlement_receipt_total_restored?(ai_receipt_attributes, candidates, lines, receipt_attributes)
        ai_attrs = normalize_receipt_attributes(ai_receipt_attributes)
        preferred_total = normalize_amount(ai_attrs[:total_amount]) || normalize_amount(candidates[:total_amount])
        settlement_total = settlement_purchase_total_from_lines(lines)
        deposit_amount = settlement_amount_from_lines(lines, profile.analysis_cash_deposit_label_pattern)

        preferred_total.present? &&
          settlement_total&.positive? &&
          deposit_amount&.positive? &&
          preferred_total.to_i == deposit_amount &&
          normalize_amount(receipt_attributes[:total_amount])&.to_i == settlement_total
      end

      def resolve_store_name(store_name, lines, ai_store_name: false)
        normalized_store_name = compact_store_name(store_name)
        return store_name if normalized_store_name.blank?

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

      def build_receipt_items_attributes(candidates, lines, ai_items, ai_name_completion_enabled: nil, skipped_negative_items: [])
        candidate_items = Array(candidates[:items])
        normalized_ai_items = normalize_items(ai_items)

        source_items =
          if candidate_items.present?
            if normalized_ai_items.present?
              merge_items(candidate_items, normalized_ai_items, lines:, ai_name_completion_enabled: ai_name_completion_enabled)
            else
              candidate_items
            end
          else
            fallback_items = build_items_from_lines(lines)

            if normalized_ai_items.present?
              merge_items(fallback_items, normalized_ai_items, lines:, ai_name_completion_enabled: ai_name_completion_enabled)
            else
              fallback_items
            end
          end
        source_items = repair_amount_only_split_items(source_items, lines)

        ai_items_present = normalized_ai_items.present?
        # product_code は保存/permit済みだがUI入力欄と検索では未活用。quantity_unit_code は編集/表示で利用する。
        source_items.each_with_index.filter_map do |item, index|
          normalized_item =
            if item.respond_to?(:with_indifferent_access)
              item.with_indifferent_access
            elsif item.respond_to?(:deep_symbolize_keys)
              item.deep_symbolize_keys.with_indifferent_access
            else
              {}.with_indifferent_access
            end

          raw_text = normalized_item[:raw_text].to_s
          quantity = normalize_quantity(normalized_item[:quantity])
          quantity_unit_code = normalize_quantity_unit_code(normalized_item[:quantity_unit_code])
          quantity_fraction_invalid = integer_quantity_fraction?(quantity, quantity_unit_code)
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
          tax_rate = normalize_rate(normalized_item[:tax_rate])
          tax_rate = BigDecimal("0") if tax_rate.nil? && non_taxable_item_text?(raw_text, normalized_item)
          if negative_item_amount?(price:, original_line_total:, line_total:)
            amount = [ price, original_line_total, line_total ].compact.map(&:to_i).find(&:negative?)&.abs
            skipped_negative_items << {
              raw_text: raw_text,
              amount: amount,
              source_line_index: normalize_non_negative_integer(normalized_item[:source_line_index]) ||
                negative_adjustment_source_line_index(raw_text, amount, lines),
              tax_rate: tax_rate,
              confidence: normalize_confidence(normalized_item[:confidence])
            }.compact
            next
          end
          raw_category = normalized_item[:category].presence
          category = normalize_category(raw_category)
          category_invalid = raw_category.present? && category.nil?
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
            # Azure Items[].QuantityUnit -> receipt_items.quantity_unit_code
            quantity_unit_code: quantity_unit_code,
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
            confidence: normalize_confidence(normalized_item[:confidence]),
            **source_evidence_attributes(normalized_item)
          }
        end
      end

      def build_receipt_adjustments_attributes(
        ai_adjustments,
        ocr_adjustment_candidates,
        lines,
        receipt_items = [],
        skipped_negative_items = [],
        receipt_payments = [],
        receipt_tax_details = [],
        source_evidence_index = [],
        invalid_review_reasons: nil
      )
        adjustment_proposals(
          ai_adjustments,
          ocr_adjustment_candidates,
          skipped_negative_items,
          lines
        ).filter_map.with_index do |entry, index|
          adjustment = entry[:proposal]
          source = entry[:source]
          next unless adjustment.is_a?(Hash) || adjustment.respond_to?(:to_h)

          normalized = (adjustment.is_a?(Hash) ? adjustment : adjustment.to_h).with_indifferent_access
          amount = normalize_amount(normalized[:amount]).to_i.abs
          next unless amount.positive?

          source_line_index = normalize_non_negative_integer(normalized[:source_line_index])
          source_text = adjustment_source_text_for(normalized, source_line_index, lines)
          validation = AdjustmentEvidenceValidator.call(
            proposal: normalized.merge(amount: amount, source_line_index: source_line_index),
            source: source,
            lines: lines,
            evidence_index: source_evidence_index,
            items: receipt_items,
            payments: receipt_payments,
            tax_details: receipt_tax_details,
            profile: profile
          )
          unless validation.accepted?
            if validation.review_required && invalid_review_reasons
              invalid_review_reasons << ADJUSTMENT_UNCERTAIN_REVIEW_REASON
            end
            next
          end

          adjustment_text = [ source_text, normalized[:label] ].compact.join(" ")
          kind = validation.kind.presence || (ReceiptAdjustment::KINDS.include?(normalized[:kind].to_s) ? normalized[:kind].to_s : "other")
          sign_value = normalized[:sign].presence || normalized[:sign_hint]
          sign = validation.sign.presence || (ReceiptAdjustment::SIGNS.include?(sign_value.to_s) ? sign_value.to_s : default_adjustment_sign(kind))
          next if adjustment_source_noise_line?(source_text, amount)

          label = adjustment_label_for(kind, normalized[:label], source_text)
          review_reasons = normalize_review_reasons(normalized[:review_reasons])
          unless validation.review_required
            review_reasons -= [ ADJUSTMENT_UNCERTAIN_REVIEW_REASON ]
          end
          needs_review = normalized[:needs_review] == true && review_reasons.any?
          needs_review ||= validation.review_required
          if kind == "other" || normalized[:kind].blank? || sign_value.blank? || validation.review_required
            needs_review = true
            review_reasons << ADJUSTMENT_UNCERTAIN_REVIEW_REASON
          end
          explicit_tax_rate = normalize_rate(normalized[:tax_rate] || normalized[:tax_rate_hint])
          inferred_tax_rate = infer_tax_rate_from_text(adjustment_text)
          tax_rate = explicit_tax_rate || inferred_tax_rate
          tax_rate_source = :explicit if tax_rate

          {
            kind: kind,
            label: label,
            amount: amount,
            sign: sign,
            tax_rate: tax_rate,
            _tax_rate_source: tax_rate_source,
            source: source,
            source_text: source_text,
            source_line_index: source_line_index,
            confidence: normalize_confidence(normalized[:confidence]),
            needs_review: needs_review,
            review_reasons: review_reasons.uniq,
            position_index: normalized[:position_index] || index + 1
          }.compact
        end
      end

      def adjustment_proposals(ai_adjustments, ocr_adjustment_candidates, skipped_negative_items, lines)
        ai_proposals = Array(ai_adjustments).map do |proposal|
          { proposal: proposal, source: "ai" }
        end
        ocr_proposals = fallback_ocr_adjustments(
          Array(ocr_adjustment_candidates) + skipped_negative_item_adjustment_candidates(skipped_negative_items, lines)
        ).reject do |proposal|
          ai_proposals.any? do |entry|
            same_adjustment_proposal?(entry[:proposal], proposal, lines)
          end
        end.map do |proposal|
          { proposal: proposal, source: "ocr" }
        end

        ai_proposals + ocr_proposals
      end

      def same_adjustment_proposal?(left, right, lines)
        return false unless left.respond_to?(:to_h) && right.respond_to?(:to_h)

        left_attributes = left.to_h.with_indifferent_access
        right_attributes = right.to_h.with_indifferent_access
        left_index = normalize_non_negative_integer(left_attributes[:source_line_index])
        right_index = normalize_non_negative_integer(right_attributes[:source_line_index])
        return false if left_index.nil? || left_index != right_index
        return false unless normalize_amount(left_attributes[:amount]).to_i.abs == normalize_amount(right_attributes[:amount]).to_i.abs

        left_kind = normalized_adjustment_proposal_kind(left_attributes, lines, left_index)
        right_kind = normalized_adjustment_proposal_kind(right_attributes, lines, right_index)
        left_sign = normalized_adjustment_proposal_sign(left_attributes, left_kind)
        right_sign = normalized_adjustment_proposal_sign(right_attributes, right_kind)

        left_kind == right_kind && left_sign == right_sign &&
          compact_adjustment_evidence_text(adjustment_source_text_for(left_attributes, left_index, lines)) ==
            compact_adjustment_evidence_text(adjustment_source_text_for(right_attributes, right_index, lines))
      end

      def normalized_adjustment_proposal_kind(adjustment, lines, source_line_index)
        kind = adjustment[:kind].to_s
        return kind if ReceiptAdjustment::KINDS.include?(kind)

        source_text = adjustment_source_text_for(adjustment, source_line_index, lines)
        sign = adjustment[:sign].presence || adjustment[:sign_hint]
        infer_ocr_adjustment_kind([ source_text, adjustment[:label] ].compact.join(" "), sign) || "other"
      end

      def normalized_adjustment_proposal_sign(adjustment, kind)
        sign = adjustment[:sign].presence || adjustment[:sign_hint]
        ReceiptAdjustment::SIGNS.include?(sign.to_s) ? sign.to_s : default_adjustment_sign(kind)
      end

      def voucher_payment_text?(text)
        text.to_s.match?(profile.analysis_voucher_payment_pattern)
      end

      def voucher_payment_base_method(text)
        source = text.to_s.strip
        amount_text = rightmost_fallback_amount_candidate(source)
        source = source.sub(amount_text.to_s, "") if amount_text.present?
        source.gsub(/[¥￥,，\d\s　]+/, " ").strip.presence || profile.voucher_label
      end

      def deduplicate_fallback_payments(payments)
        seen = {}

        Array(payments).filter_map do |payment|
          next payment if voucher_payment_text?(payment[:method])

          key = [ payment[:method], payment[:amount] ]
          next if seen[key]

          seen[key] = true
          payment
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

      def skipped_negative_item_adjustment_candidates(skipped_negative_items, lines)
        Array(skipped_negative_items).filter_map do |item|
          normalized = item.with_indifferent_access
          amount = normalize_amount(normalized[:amount]).to_i.abs
          next unless amount.positive?

          source_line_index = normalize_non_negative_integer(normalized[:source_line_index])
          next if source_line_index.nil?

          source_text = Array(lines)[source_line_index].to_s.strip.presence || normalized[:raw_text].to_s.strip.presence
          next unless negative_adjustment_source_supported?(source_line_index, normalized[:raw_text], amount, lines)

          raw_text = normalized[:raw_text].to_s.strip.presence || source_text
          {
            kind: infer_ocr_adjustment_kind(source_text || raw_text, "discount"),
            label: raw_text,
            amount: amount,
            sign_hint: "discount",
            tax_rate_hint: normalized[:tax_rate],
            source_text: raw_text,
            source_line_index: source_line_index,
            confidence: normalized[:confidence] || OCR_ADJUSTMENT_FALLBACK_CONFIDENCE_THRESHOLD,
            needs_review: true,
            review_reasons: [ ADJUSTMENT_UNCERTAIN_REVIEW_REASON ]
          }
        end
      end

      def build_receipt_payments_attributes(candidates, lines, receipt_total: nil)
        total = normalize_amount(receipt_total || candidates[:total_amount])
        structured_payments = Array(candidates[:payments]).map do |payment|
          normalized_payment = payment.respond_to?(:deep_symbolize_keys) ? payment.deep_symbolize_keys : {}

          {
            # Azure Payments[].Method -> receipt_payments.method
            method: normalized_payment[:method],
            # Azure Payments[].Amount -> receipt_payments.amount
            amount: normalize_amount(normalized_payment[:amount]),
            **source_evidence_attributes(normalized_payment)
          }.compact
        end
        return normalize_structured_payments_with_settlement(structured_payments, lines, total, tax_details: candidates[:tax_details]) if structured_payments.present?

        explicit_fallback_payments = fallback_payments_from_lines(
          lines,
          receipt_total: total,
          fallback_method: candidates[:payment_method_text]
        )
        return explicit_fallback_payments if payment_sum_matches_total?(explicit_fallback_payments, total)

        deposit_change_payment = cash_payment_from_deposit_change_lines(
          lines,
          total,
          tax_details: candidates[:tax_details],
          allow_tax_detail_conflict: settlement_purchase_total_from_lines(lines) == total&.to_i &&
            !external_tax_detail_context?(candidates[:tax_details])
        )
        return [ deposit_change_payment ] if deposit_change_payment.present?

        fallback_payments_from_lines(
          lines,
          receipt_total: total,
          fallback_method: candidates[:payment_method_text]
        )
      end

      def cash_payment_from_deposit_change_lines(lines, receipt_total, tax_details: [], allow_tax_detail_conflict: false)
        total = normalize_amount(receipt_total)&.to_i
        return nil unless total&.positive?
        return nil if !allow_tax_detail_conflict && external_tax_details_conflict_with_receipt_total?(tax_details, total)

        deposit_amount = settlement_amount_from_lines(lines, profile.analysis_cash_deposit_label_pattern)
        change_amount = settlement_amount_from_lines(lines, profile.analysis_cash_change_label_pattern)
        return nil unless deposit_amount&.positive? && !change_amount.nil?
        return nil unless deposit_amount - change_amount == total

        {
          method: "cash",
          amount: total
        }
      end

      def normalize_structured_payments_with_settlement(payments, lines, receipt_total, tax_details: [])
        total = normalize_amount(receipt_total)&.to_i
        settlement_total = settlement_purchase_total_from_lines(lines)
        return payments unless total&.positive? && settlement_total == total
        return payments if external_tax_detail_context?(tax_details)

        deposit_amount = settlement_amount_from_lines(lines, profile.analysis_cash_deposit_label_pattern)
        return payments unless deposit_amount&.positive?

        Array(payments).map do |payment|
          next payment unless payment[:amount].to_i == deposit_amount
          next payment unless normalize_detected_payment_method(
            Analysis::ReceiptFallbackPatterns.detect_payment_method(payment[:method])
          ) == "cash"

          payment.merge(amount: total)
        end
      end

      def add_cash_difference_payment(payments, lines, receipt_total)
        normalized_payments = Array(payments).map(&:dup)
        return normalized_payments if normalized_payments.blank?

        total = normalize_amount(receipt_total)&.to_i
        return normalized_payments unless total&.positive?

        payment_sum = normalized_payments.sum { |payment| payment[:amount].to_i }
        missing_amount = total - payment_sum
        return normalized_payments unless missing_amount.positive?

        deposit_amount = settlement_amount_from_lines(lines, profile.analysis_cash_deposit_label_pattern)
        change_amount = settlement_amount_from_lines(lines, profile.analysis_cash_change_label_pattern)
        return normalized_payments unless deposit_amount&.positive? && !change_amount.nil?
        return normalized_payments unless deposit_amount - change_amount == missing_amount

        normalized_payments + [ { method: "cash", amount: missing_amount } ]
      end

      def payment_sum_matches_total?(payments, total)
        normalized_total = normalize_amount(total)&.to_i
        return false unless normalized_total&.positive?

        Array(payments).present? &&
          Array(payments).sum { |payment| payment[:amount].to_i } == normalized_total
      end

      def external_tax_details_conflict_with_receipt_total?(tax_details, receipt_total)
        details = usable_tax_details_with_gross_amount(tax_details)
        return false if details.blank?

        net_sum = details.sum { |tax_detail| tax_detail[:net_amount] }
        gross_sum = details.sum { |tax_detail| tax_detail[:gross_amount] }

        net_sum == receipt_total && gross_sum != receipt_total
      end

      def external_tax_detail_context?(tax_details)
        Array(tax_details).any? do |tax_detail|
          description = tax_detail.respond_to?(:[]) ? tax_detail[:description] || tax_detail["description"] : nil
          description.to_s.match?(profile.analysis_external_tax_description_pattern)
        end
      end

      def settlement_amount_from_lines(lines, label_pattern)
        Array(lines).each_with_index do |line, index|
          next unless settlement_label_line?(lines, index, label_pattern)

          same_line_amount = settlement_amounts_from_text(line).max
          return same_line_amount if same_line_amount.present?

          neighboring_amount = Array(lines)[(index + 1)..(index + 3)].to_a.filter_map do |candidate|
            settlement_amounts_from_text(candidate).max
          end.first
          return neighboring_amount if neighboring_amount.present?
        end

        nil
      end

      def settlement_purchase_total_from_lines(lines)
        deposit_amount = settlement_amount_from_lines(lines, profile.analysis_cash_deposit_label_pattern)
        change_amount = settlement_amount_from_lines(lines, profile.analysis_cash_change_label_pattern)
        return nil unless deposit_amount&.positive? && !change_amount.nil?

        total = deposit_amount - change_amount
        total.positive? ? total : nil
      end

      def settlement_label_line?(lines, index, label_pattern)
        text = Array(lines)[index].to_s.unicode_normalize(:nfkc)
        return true if text.match?(label_pattern)
        return false if settlement_amounts_from_text(text).present?

        joined = Array(lines)[index, 2].join.unicode_normalize(:nfkc)
        joined.match?(label_pattern)
      end

      def fallback_payments_from_lines(lines, receipt_total: nil, fallback_method: nil)
        total = normalize_amount(receipt_total)&.to_i
        payments = Array(lines).each_with_index.filter_map do |line, index|
          point_payment = point_payment_from_payment_block(lines, index)
          next point_payment if point_payment.present?

          next unless fallback_payment_context_line?(line)

          amount_info = fallback_payment_context_amount_with_source(lines, index, receipt_total: total)
          amount = amount_info&.fetch(:amount, nil)
          next unless amount&.positive?

          method = cash_total_payment_line?(line) ? "cash" : fallback_payment_method_text(line)
          method = nil if fallback_payment_amount_label_line?(line)
          method = fallback_method.presence if method.blank?
          next if method.blank?

          {
            method: method,
            amount: amount,
            source_text: line.to_s.strip,
            source_line_index: index,
            source_index: index,
            amount_source: amount_info[:source],
            transaction_context: fallback_payment_transaction_context_line?(line)
          }
        end
        payments = deduplicate_fallback_payments(payments)

        select_fallback_payments(payments, receipt_total: total)
      end

      def point_payment_from_payment_block(lines, index)
        return nil unless point_payment_context_line?(lines, index)

        amount_info = point_payment_amount_with_source(lines, index)
        amount = amount_info&.fetch(:amount, nil)
        return nil unless amount&.positive?

        {
          method: point_payment_method_text(lines[index]),
          amount: amount,
          source_text: Array(lines)[index].to_s.strip,
          source_line_index: index,
          source_index: index,
          amount_source: amount_info[:source],
          transaction_context: true
        }
      end

      def point_payment_context_line?(lines, index)
        text = Array(lines)[index].to_s.unicode_normalize(:nfkc).strip
        return false if text.blank?
        return false if text.match?(profile.analysis_point_display_line_pattern)
        return false unless text.match?(profile.analysis_point_payment_line_pattern)

        text.match?(profile.analysis_point_payment_strong_line_pattern) ||
          explicit_money_amount_from_text(text).present? ||
          payment_block_context?(lines, index)
      end

      def payment_block_context?(lines, index)
        context = lines_around(lines, index, before: 3, after: 0).join(" ").unicode_normalize(:nfkc)
        context.match?(profile.analysis_payment_block_anchor_pattern)
      end

      def point_payment_amount_with_source(lines, index)
        same_line_amount = explicit_money_amount_from_text(lines[index])
        return { amount: same_line_amount, source: :same_line } if same_line_amount.present?

        ((index + 1)..(index + 2)).each do |candidate_index|
          candidate = Array(lines)[candidate_index]
          next if candidate.blank?

          amount = explicit_money_amount_from_text(candidate)
          return { amount: amount, source: :neighbor } if amount.present?
          break if payment_method_like_line?(candidate)
        end

        nil
      end

      def explicit_money_amount_from_text(text)
        amounts = text.to_s.unicode_normalize(:nfkc).to_enum(:scan, profile.analysis_explicit_payment_money_pattern).filter_map do |match|
          normalize_amount(match)&.to_i
        end.select(&:positive?)
        amounts.max
      end

      def payment_method_like_line?(line)
        text = line.to_s.unicode_normalize(:nfkc)
        text.match?(profile.analysis_fallback_payment_line_pattern) ||
          text.match?(profile.analysis_point_payment_line_pattern) ||
          text.match?(profile.analysis_payment_block_anchor_pattern)
      end

      def point_payment_method_text(line)
        text = line.to_s.unicode_normalize(:nfkc).strip
        text = text.gsub(profile.analysis_explicit_payment_money_pattern, " ")
        text = text.gsub(/(?<![A-Za-z0-9])\d+\s*p(?:t|ts|oint|oints)?(?![A-Za-z0-9])/i, " ")
        text.gsub(/[¥￥,，\d\s　:：]+/, " ").strip.presence || profile.point_usage_label
      end

      def fallback_payment_context_line?(line)
        text = line.to_s.unicode_normalize(:nfkc).strip
        return false if text.blank?
        return false if text.match?(profile.analysis_fallback_payment_excluded_pattern)
        return false if fallback_payment_metadata_label_line?(text)
        return false if fallback_payment_support_only_line?(text)
        return true if fallback_payment_amount_label_line?(text)
        return false unless text.match?(profile.analysis_fallback_payment_line_pattern) || fallback_payment_amount_label_line?(text)

        fallback_payment_amount(text).present? || text.match?(profile.analysis_fallback_payment_action_pattern)
      end

      def fallback_payment_support_only_line?(line)
        text = line.to_s.unicode_normalize(:nfkc)
        text.match?(profile.analysis_fallback_payment_support_only_pattern) &&
          !text.match?(profile.analysis_fallback_payment_transaction_context_pattern)
      end

      def fallback_payment_transaction_context_line?(line)
        line.to_s.unicode_normalize(:nfkc).match?(profile.analysis_fallback_payment_transaction_context_pattern)
      end

      def fallback_payment_neighbor_amount_allowed?(line)
        text = line.to_s.unicode_normalize(:nfkc)
        text.match?(profile.analysis_fallback_payment_action_pattern) || fallback_payment_amount_label_line?(text)
      end

      def fallback_payment_context_amount(lines, index, receipt_total:)
        fallback_payment_context_amount_with_source(lines, index, receipt_total:)&.fetch(:amount, nil)
      end

      def fallback_payment_context_amount_with_source(lines, index, receipt_total:)
        line = Array(lines)[index].to_s
        if cash_total_payment_line?(line)
          amount = cash_total_payment_amount(lines, index, receipt_total:)
          return { amount: amount, source: :cash_total } if amount.present?

          return nil
        end

        amount = low_quality_payment_amount_from_fragment(line, receipt_total)
        return { amount: amount, source: :same_line_fragment } if amount.present?

        amount = fallback_payment_amount(line, receipt_total: receipt_total)
        return { amount: amount, source: :same_line } if amount.present?

        return nil unless fallback_payment_neighbor_amount_allowed?(line)

        neighbor_line = Array(lines)[index + 1]
        amount = low_quality_payment_amount_from_fragment(neighbor_line, receipt_total)
        return { amount: amount, source: :neighbor_fragment } if amount.present?

        amount = fallback_payment_amount(neighbor_line, receipt_total: receipt_total)
        return nil if amount.blank?

        source = fallback_payment_amount_label_line?(line) ? :amount_label_neighbor : :neighbor
        { amount: amount, source: source }
      end

      def cash_total_payment_line?(line)
        line.to_s.unicode_normalize(:nfkc).gsub(/[[:space:]]/, "").match?(profile.analysis_cash_total_payment_pattern)
      end

      def cash_total_payment_amount(lines, index, receipt_total:)
        total = normalize_amount(receipt_total)&.to_i
        same_line_amount = fallback_payment_amount(Array(lines)[index], receipt_total: total)
        return same_line_amount if cash_total_payment_amount_allowed?(same_line_amount, total)

        nearby_total = nearby_receipt_total_amount(lines, index, total)
        return nearby_total if nearby_total.present?

        return nil if total&.positive?
        return nil unless fallback_payment_neighbor_amount_allowed?(Array(lines)[index])

        fallback_payment_amount(Array(lines)[index + 1], receipt_total: total)
      end

      def cash_total_payment_amount_allowed?(amount, total)
        return false if amount.blank?
        return true unless total&.positive?

        amount.to_i == total
      end

      def nearby_receipt_total_amount(lines, index, total)
        return nil unless total&.positive?

        preceding_indices = ((index - 4)...index).to_a.reverse
        following_indices = ((index + 1)..(index + 3)).to_a

        found = (preceding_indices + following_indices).find do |candidate_index|
          candidate_line = Array(lines)[candidate_index]
          next false if candidate_line.blank?

          positive_amounts_from_text(candidate_line).include?(total)
        end

        found ? total : nil
      end

      def fallback_payment_amount(line, receipt_total: nil)
        text = fallback_payment_amount_source(line)
        return nil if fallback_payment_amount_noise_line?(text)
        return nil if text.match?(/[▲△\-−]\s*[¥￥]?\s*\d/)

        matches = text.to_enum(:scan, profile.analysis_fallback_amount_candidate_pattern).map { Regexp.last_match.to_s }
        amounts = matches.filter_map { |match| normalize_amount(match)&.to_i }.select(&:positive?)
        return nil if amounts.blank?

        total = normalize_amount(receipt_total)&.to_i
        return total if total&.positive? && amounts.include?(total)

        amounts.max
      end

      def low_quality_payment_amount_from_fragment(line, receipt_total)
        total = normalize_amount(receipt_total)&.to_i
        return nil unless total && total >= 100

        text = line.to_s.unicode_normalize(:nfkc)
        return nil unless text.match?(/[¥￥]\s*\d(?:\s+\d)+/)

        fragment = text.scan(/\d/).join
        total_digits = total.to_s
        return nil unless fragment.length >= 2 && fragment.length < total_digits.length
        return nil unless digit_subsequence?(fragment, total_digits)

        total
      end

      def digit_subsequence?(fragment, source)
        position = 0
        fragment.each_char.all? do |digit|
          found_at = source.index(digit, position)
          if found_at
            position = found_at + 1
            true
          else
            false
          end
        end
      end

      def fallback_payment_amount_source(line)
        line.to_s.unicode_normalize(:nfkc).gsub(PARENTHESIZED_PAYMENT_CODE_PATTERN, "")
      end

      def fallback_payment_amount_label_line?(line)
        text = line.to_s.unicode_normalize(:nfkc).gsub(/[[:space:]:：]/, "")
        text.match?(profile.analysis_fallback_payment_amount_label_pattern)
      end

      def fallback_payment_metadata_label_line?(line)
        line.to_s.unicode_normalize(:nfkc).match?(profile.analysis_fallback_payment_metadata_label_pattern)
      end

      def fallback_payment_amount_noise_line?(line)
        text = line.to_s.unicode_normalize(:nfkc)
        text.match?(profile.analysis_fallback_payment_amount_noise_pattern) ||
          text.match?(profile.analysis_fallback_payment_address_amount_noise_pattern)
      end

      def select_fallback_payments(payments, receipt_total:)
        candidates = Array(payments)
        total = normalize_amount(receipt_total)&.to_i
        exact_matches =
          if total&.positive?
            candidates.select do |payment|
              payment[:amount].to_i == total && reliable_total_match_payment_candidate?(payment)
            end
          else
            []
          end

        selected =
          if exact_matches.present?
            [ exact_matches.min_by { |payment| payment[:source_index].to_i } ]
          elsif total&.positive? &&
                candidates.sum { |payment| payment[:amount].to_i } == total &&
                candidates.all? { |payment| reliable_total_match_payment_candidate?(payment) }
            candidates
          elsif total&.positive?
            candidates.select { |payment| payment[:transaction_context] || voucher_payment_text?(payment[:method]) }
          else
            candidates
          end
        selected.map { |payment| payment.except(:source_index, :transaction_context, :amount_source) }
      end

      def reliable_total_match_payment_candidate?(payment)
        return true if payment[:transaction_context]
        return true if payment[:amount_source] == :cash_total
        return true if voucher_payment_text?(payment[:method])

        strong_fallback_payment_method?(payment[:method]) &&
          %i[same_line neighbor amount_label_neighbor].include?(payment[:amount_source])
      end

      def strong_fallback_payment_method?(method)
        normalize_detected_payment_method(
          Analysis::ReceiptFallbackPatterns.detect_payment_method(method)
        ).present?
      end

      def positive_amounts_from_text(text)
        text.to_s.to_enum(:scan, profile.analysis_adjustment_amount_candidate_pattern).filter_map do |match|
          normalize_amount(match)&.to_i&.abs
        end.select(&:positive?)
      end

      def settlement_amounts_from_text(text)
        text.to_s.unicode_normalize(:nfkc).to_enum(:scan, profile.analysis_settlement_amount_candidate_pattern).filter_map do |match|
          normalize_settlement_amount(match)&.to_i&.abs
        end.select { |amount| amount >= 0 }
      end

      def normalize_settlement_amount(value)
        text = value.to_s.unicode_normalize(:nfkc).tr("，", ",")
        text = text.gsub(/(?<=\d)\.(?=\d{3}(?:\D|\z))/, ",")
        normalize_amount(text)
      end

      def fallback_payment_method_text(line)
        text = fallback_payment_amount_source(line).strip
        amount_text = rightmost_fallback_amount_candidate(text)
        text = text.sub(amount_text.to_s, "") if amount_text.present?
        text.gsub(/[¥￥,，\d\s　]+/, " ").strip.presence
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
            net_amount: normalize_amount(normalized_tax_detail[:net_amount]),
            **source_evidence_attributes(normalized_tax_detail)
          }.compact
        end
      end

      def source_evidence_attributes(value)
        normalized = value.respond_to?(:to_h) ? value.to_h.with_indifferent_access : {}.with_indifferent_access

        normalized.slice(
          :source_provider,
          :source_field_path,
          :source_line_index,
          :source_span_start,
          :source_span_end
        ).compact.to_h.symbolize_keys
      end

      def recover_receipt_tax_details_from_lines(tax_details, lines, receipt_attributes)
        tax_details = apply_tax_rate_target_labels_from_lines(tax_details, lines)
        return tax_details if complete_multi_rate_tax_details?(tax_details)

        inferred_tax_details = tax_details_from_rate_targets(lines, receipt_attributes, tax_details)
        inferred_tax_details = tax_details_from_rate_summary_lines(lines, receipt_attributes, tax_details) if inferred_tax_details.blank?
        inferred_tax_details = tax_details_from_tax_section_pairs(lines, receipt_attributes) if inferred_tax_details.blank?
        return tax_details if inferred_tax_details.blank?

        inferred_tax_details
      end

      def apply_tax_rate_target_labels_from_lines(tax_details, lines)
        targets = tax_rate_targets_from_lines(lines)
        return tax_details if targets.blank?

        Array(tax_details).map do |tax_detail|
          next tax_detail if tax_detail[:description].to_s.match?(profile.analysis_external_tax_description_pattern)

          rate = normalize_rate(tax_detail[:rate])
          amount = normalize_amount(tax_detail[:amount])&.to_i
          net_amount = normalize_amount(tax_detail[:net_amount])&.to_i
          next tax_detail unless rate&.positive? && amount&.positive? && net_amount&.positive?

          target = targets.find do |candidate|
            candidate[:rate] == rate &&
              (candidate[:tax_amount].blank? || candidate[:tax_amount].to_i == amount) &&
              [ net_amount, net_amount + amount ].include?(candidate[:gross_amount])
          end
          next tax_detail unless target

          tax_detail.merge(description: profile.tax_rate_target_label(rate_percentage_label(rate)))
        end
      end

      def complete_multi_rate_tax_details?(tax_details)
        details = usable_tax_details_with_gross_amount(tax_details)
        details.map { |tax_detail| tax_detail[:rate] }.uniq.size > 1
      end

      def tax_details_from_rate_targets(lines, receipt_attributes, tax_details)
        receipt_total = normalize_amount(receipt_attributes[:total_amount])&.to_i
        receipt_tax = normalize_amount(receipt_attributes[:tax_amount])&.to_i
        Analysis::TaxDetailLineEvidenceExtractor.call(
          lines: lines,
          receipt_total: receipt_total,
          receipt_tax: receipt_tax,
          existing_tax_details: tax_details,
          profile: profile
        )
      end

      def tax_rate_targets_from_lines(lines)
        Array(lines).each_with_index.filter_map do |line, index|
          rate = tax_target_rate_from_line(line)
          next if rate.blank?

          amount = tax_target_amount_near_line(lines, index)
          next unless amount&.positive?

          {
            rate: rate,
            gross_amount: amount,
            tax_amount: tax_target_tax_amount_near_line(lines, index, rate, amount)
          }
        end.uniq { |target| [ target[:rate].to_s("F"), target[:gross_amount] ] }
      end

      def tax_details_from_tax_section_pairs(lines, receipt_attributes)
        details = tax_section_pair_details_from_lines(lines)
        return [] if details.blank?

        tax_sum = details.sum { |detail| detail[:amount].to_i }
        explicit_tax_total = tax_total_amount_from_lines(lines)
        receipt_tax = normalize_amount(receipt_attributes[:tax_amount])&.to_i
        return [] if explicit_tax_total&.positive? && explicit_tax_total != tax_sum
        return [] if receipt_tax&.positive? && receipt_tax != tax_sum

        receipt_total = normalize_amount(receipt_attributes[:total_amount])&.to_i
        gross_sum = details.sum { |detail| detail[:net_amount].to_i + detail[:amount].to_i }
        return [] if receipt_total&.positive? && receipt_total != gross_sum

        details
      end

      def tax_section_gross_total_from_lines(lines)
        details = tax_section_pair_details_from_lines(lines)
        return nil if details.blank?

        tax_sum = details.sum { |detail| detail[:amount].to_i }
        explicit_tax_total = tax_total_amount_from_lines(lines)
        return nil if explicit_tax_total&.positive? && explicit_tax_total != tax_sum

        details.sum { |detail| detail[:net_amount].to_i + detail[:amount].to_i }
      end

      def tax_total_amount_from_lines(lines)
        Array(lines).each_with_index do |line, index|
          next unless line.to_s.unicode_normalize(:nfkc).match?(profile.analysis_tax_total_line_pattern)

          amount = Array(lines)[index, 3].to_a.flat_map do |candidate|
            positive_amounts_from_text(candidate)
          end.select(&:positive?).max
          return amount if amount.present?
        end

        nil
      end

      def tax_section_pair_details_from_lines(lines)
        rate_entries = tax_target_rate_entries_from_lines(lines)
        return [] if rate_entries.size < 2

        amounts = tax_section_amount_entries(lines, rate_entries.first[:index])
        assignments = tax_section_pair_assignments(rate_entries, amounts)
        return [] if assignments.blank?

        assignments.map do |assignment|
          gross = assignment[:gross_amount]
          tax = assignment[:tax_amount]
          {
            description: profile.tax_rate_target_label(rate_percentage_label(assignment[:rate])),
            rate: assignment[:rate],
            net_amount: gross - tax,
            amount: tax
          }
        end
      end

      def tax_target_rate_entries_from_lines(lines)
        Array(lines).each_with_index.filter_map do |line, index|
          rates = tax_target_rate_candidates_from_line(line)
          next if rates.blank?

          { index: index, rates: rates }
        end
      end

      def tax_target_rate_candidates_from_line(line)
        text = line.to_s.unicode_normalize(:nfkc)
        return [] unless text.match?(profile.analysis_tax_target_marker_pattern)
        return [] if text.match?(profile.analysis_tax_amount_description_pattern)

        text.scan(/(\d+(?:\.\d+)?)\s*[%％]/).flatten.flat_map do |raw_rate|
          tax_rate_candidates_from_text_number(raw_rate)
        end.uniq
      end

      def tax_rate_candidates_from_text_number(raw_rate)
        candidates = [ normalize_rate(raw_rate) ].compact
        if raw_rate.to_s.include?(".")
          decimal_tail = raw_rate.to_s.split(".").last
          candidates << normalize_rate(decimal_tail) if decimal_tail.match?(/\A(?:8|10)\z/)
        end

        candidates.select(&:positive?).uniq
      end

      def tax_section_amount_entries(lines, first_rate_index)
        section = Array(lines)[first_rate_index..].to_a.take_while do |line|
          !line.to_s.match?(profile.analysis_tax_total_line_pattern)
        end
        section.each_with_index.flat_map do |line, offset|
          positive_amounts_from_text(line).select { |amount| amount > 20 }.map do |amount|
            { index: first_rate_index + offset, amount: amount }
          end
        end
      end

      def tax_section_pair_assignments(rate_entries, amounts)
        assignments = tax_section_pair_assignment_paths(rate_entries, amounts, 0, [])
        return [] unless assignments.one?

        assignments.first
      end

      def tax_section_pair_assignment_paths(rate_entries, amounts, rate_index, selected)
        return [ selected ] if rate_index >= rate_entries.size

        used_indexes = selected.flat_map { |entry| [ entry[:gross_index], entry[:tax_index] ] }
        entry = rate_entries[rate_index]
        possible_tax_section_pairs(entry[:rates], amounts, used_indexes).flat_map do |pair|
          tax_section_pair_assignment_paths(rate_entries, amounts, rate_index + 1, selected + [ pair ])
        end
      end

      def possible_tax_section_pairs(rates, amounts, used_indexes)
        Array(rates).flat_map do |rate|
          amounts.combination(2).flat_map do |left, right|
            [
              tax_section_pair_for(rate, left, right),
              tax_section_pair_for(rate, right, left)
            ]
          end
        end.compact.reject do |pair|
          used_indexes.include?(pair[:gross_index]) || used_indexes.include?(pair[:tax_index])
        end.uniq { |pair| [ pair[:rate].to_s("F"), pair[:gross_index], pair[:tax_index] ] }
      end

      def tax_section_pair_for(rate, gross_entry, tax_entry)
        gross = gross_entry[:amount].to_i
        tax = tax_entry[:amount].to_i
        return nil unless gross > tax
        return nil unless included_tax_amount_matches?(gross, rate, tax)

        {
          rate: rate,
          gross_amount: gross,
          tax_amount: tax,
          gross_index: gross_entry[:index],
          tax_index: tax_entry[:index]
        }
      end

      def tax_target_amount_near_line(lines, index)
        lines_window_until_next_tax_target(lines, index).filter_map do |line|
          tax_target_amount_from_line(line)
        end.find(&:positive?)
      end

      def tax_target_tax_amount_near_line(lines, index, rate, gross_amount)
        amounts = lines_window_until_next_tax_target(lines, index).flat_map do |line|
          positive_amounts_from_text(line).select { |amount| amount > 20 }
        end
        gross_seen = false

        amounts.find do |amount|
          if amount == gross_amount && !gross_seen
            gross_seen = true
            next false
          end

          included_tax_amount_matches?(gross_amount, rate, amount)
        end
      end

      def tax_details_from_rate_summary_lines(lines, receipt_attributes, tax_details)
        receipt_total = normalize_amount(receipt_attributes[:total_amount])&.to_i
        receipt_tax = normalize_amount(receipt_attributes[:tax_amount])&.to_i
        source_details = incomplete_tax_details_by_rate(tax_details)
        return [] unless receipt_total&.positive? && receipt_tax&.positive?
        return [] if source_details.blank?

        inferred = Array(lines).each_with_index.filter_map do |line, index|
          rate = tax_summary_rate_from_line(line)
          next if rate.blank?

          source_detail = source_details[rate.to_s("F")]
          next if source_detail.blank?

          tax = source_detail[:amount]
          gross = tax_summary_gross_amount(lines, index, rate, tax)
          next unless gross&.positive?

          {
            description: profile.tax_rate_target_label(rate_percentage_label(rate)),
            rate: rate,
            net_amount: gross - tax,
            amount: tax
          }
        end.uniq { |detail| detail[:rate].to_s("F") }

        return [] if inferred.blank?
        return [] unless inferred.sum { |detail| detail[:net_amount] + detail[:amount] } == receipt_total
        return [] unless inferred.sum { |detail| detail[:amount] } == receipt_tax

        inferred
      end

      def incomplete_tax_details_by_rate(tax_details)
        Array(tax_details).each_with_object({}) do |tax_detail, details|
          rate = normalize_rate(tax_detail[:rate])
          amount = normalize_amount(tax_detail[:amount])
          net_amount = normalize_amount(tax_detail[:net_amount])
          next unless rate&.positive? && amount&.positive?
          next if net_amount&.positive?

          details[rate.to_s("F")] = { rate: rate, amount: amount.to_i }
        end
      end

      def tax_summary_rate_from_line(line)
        text = line.to_s.unicode_normalize(:nfkc)
        return nil if text.match?(profile.analysis_external_tax_description_pattern)

        match = text.match(/(\d+(?:\.\d+)?)\s*[%％]/)
        normalize_rate(match[1]) if match
      end

      def tax_summary_gross_amount(lines, index, rate, tax)
        amounts = Array(lines)[index, 4].to_a.flat_map do |line|
          positive_amounts_from_text(line).select { |amount| amount > 20 }
        end

        amounts.find do |amount|
          amount != tax && included_tax_amount(amount, rate) == tax
        end
      end

      def tax_target_rate_from_line(line)
        tax_target_rate_candidates_from_line(line).first
      end

      def tax_target_amount_from_line(line)
        positive_amounts_from_text(line).select { |amount| amount > 20 }.max
      end

      def lines_window_until_next_tax_target(lines, index)
        Array(lines)[index, 4].to_a.take_while.with_index do |line, offset|
          offset.zero? || tax_target_rate_from_line(line).blank?
        end
      end

      def included_tax_amount(gross_amount, rate)
        tax = BigDecimal(gross_amount.to_s) * rate / (BigDecimal("1") + rate)
        ReceiptAmountService.apply_rounding(tax, :floor)
      end

      def included_tax_amount_from_net(net_amount, rate)
        tax = BigDecimal(net_amount.to_s) * rate
        ReceiptAmountService.apply_rounding(tax, :floor)
      end

      def included_tax_amount_matches?(gross_amount, rate, amount)
        tax = BigDecimal(gross_amount.to_s) * rate / (BigDecimal("1") + rate)
        %i[floor round ceil].any? do |rounding_mode|
          ReceiptAmountService.apply_rounding(tax, rounding_mode) == amount.to_i
        end
      end

      def rate_percentage_label(rate)
        value = rate * 100
        value.frac.zero? ? value.to_i.to_s : value.to_s("F")
      end

      def apply_single_tax_detail_rate_policy(items, adjustments, tax_details, receipt_attributes)
        return unless items.present?

        override_rate = single_tax_detail_rate_covering_total(tax_details, receipt_attributes)
        if override_rate && single_tax_detail_matches_taxable_total?(items, adjustments, tax_details, receipt_attributes)
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
        return nil unless matches.size == usable_tax_details.size

        {
          reason: "tax_detail_amount_match",
          source: "printed_tax_detail",
          matches: matches,
          item_count: matches.count { |match| match[:target] == "item" },
          adjustment_count: matches.count { |match| match[:target] == "adjustment" }
        }
      end

      def apply_tax_marker_group_amount_match_policy(items, tax_details, lines)
        positive_items = Array(items).select { |item| normalize_amount(item[:line_total]).to_i.positive? }
        usable_tax_details = usable_tax_details_with_gross_amount(tax_details)
        return nil unless positive_items.present? && usable_tax_details.size >= 2

        sorted_details = usable_tax_details.sort_by { |tax_detail| tax_detail[:rate] }
        reduced_detail = sorted_details.first
        standard_details = sorted_details.drop(1)
        return nil unless standard_details.one?

        standard_detail = standard_details.first
        marked_items, unmarked_items = positive_items.partition do |item|
          item_reduced_tax_marker?(item, lines)
        end
        return nil if marked_items.blank? || unmarked_items.blank?
        return nil unless item_amount_sum(marked_items) == reduced_detail[:gross_amount]
        return nil unless item_amount_sum(unmarked_items) == standard_detail[:gross_amount]

        changed_item_count = 0
        marked_items.each do |item|
          changed_item_count += 1 unless normalize_rate(item[:tax_rate]) == reduced_detail[:rate]
          item[:tax_rate] = reduced_detail[:rate]
        end
        unmarked_items.each do |item|
          changed_item_count += 1 unless normalize_rate(item[:tax_rate]) == standard_detail[:rate]
          item[:tax_rate] = standard_detail[:rate]
        end

        {
          reason: "tax_marker_group_amount_match",
          source: "printed_tax_detail",
          matches: [
            { target: "items", amount: reduced_detail[:gross_amount], rate: reduced_detail[:rate].to_s("F") },
            { target: "items", amount: standard_detail[:gross_amount], rate: standard_detail[:rate].to_s("F") }
          ],
          item_count: changed_item_count,
          adjustment_count: 0
        }
      end

      def usable_tax_details_with_target_amount(tax_details)
        Array(tax_details).filter_map do |tax_detail|
          rate = normalize_rate(tax_detail[:rate])
          amount = normalize_amount(tax_detail[:amount])
          target_amount = normalize_amount(tax_detail[:net_amount])
          next unless rate&.positive?
          next unless usable_tax_detail_amount?(tax_detail, rate, amount, target_amount)
          next unless target_amount&.positive?

          {
            rate: rate,
            amount: amount,
            target_amount: target_amount.to_i
          }
        end
      end

      def usable_tax_details_with_gross_amount(tax_details)
        Array(tax_details).filter_map do |tax_detail|
          rate = normalize_rate(tax_detail[:rate])
          amount = normalize_amount(tax_detail[:amount])
          net_amount = normalize_amount(tax_detail[:net_amount])
          next unless rate&.positive?
          next unless usable_tax_detail_amount?(tax_detail, rate, amount, net_amount)
          next unless net_amount&.positive?

          {
            rate: rate,
            amount: amount.to_i,
            net_amount: net_amount.to_i,
            gross_amount: net_amount.to_i + amount.to_i
          }
        end
      end

      def usable_tax_detail_amount?(tax_detail, rate, amount, net_amount)
        return false if amount.nil?
        return true if amount.positive?
        return false unless amount.zero? && net_amount&.positive?

        description = tax_detail[:description].to_s
        net_basis_zero_tax_detail?(description, rate, net_amount) ||
          gross_basis_zero_tax_detail?(description, rate, net_amount)
      end

      def net_basis_zero_tax_detail?(description, rate, net_amount)
        return false unless description.match?(profile.amount_tax_detail_net_pattern) || description.match?(profile.amount_tax_detail_intermediate_pattern)

        included_tax_amount_from_net(net_amount, rate).zero?
      end

      def gross_basis_zero_tax_detail?(description, rate, gross_amount)
        return false unless description.match?(profile.amount_tax_detail_gross_pattern) || description.match?(profile.analysis_tax_target_marker_pattern)

        included_tax_amount(gross_amount, rate).zero?
      end

      def item_reduced_tax_marker?(item, lines)
        item_amount = normalize_amount(item[:line_total])&.to_i
        return false unless item_amount&.positive?

        item_line_indexes(item, lines).any? do |index|
          Array(lines)[index..(index + 4)].to_a.any? do |line|
            line.to_s.match?(profile.analysis_reduced_tax_marker_pattern) &&
              positive_amounts_from_text(line).include?(item_amount)
          end
        end
      end

      def item_line_indexes(item, lines)
        raw_text = compact_item_text(item[:raw_text])
        return [] if raw_text.blank?

        Array(lines).each_with_index.filter_map do |line, index|
          line_text = compact_item_text(line)
          next if line_text.blank?

          index if line_text.include?(raw_text) || raw_text.include?(line_text)
        end
      end

      def compact_item_text(value)
        value.to_s.unicode_normalize(:nfkc).gsub(/[[:space:]]+/, "").strip.downcase.presence
      end

      def item_amount_sum(items)
        Array(items).sum { |item| normalize_amount(item[:line_total]).to_i }
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

        usable_tax_details = usable_tax_details_with_gross_amount(tax_details)
        return nil unless usable_tax_details.one?

        tax_detail = usable_tax_details.first
        return tax_detail[:rate] if tax_detail_covers_total_amount?(tax_detail, total_amount)

        nil
      end

      def single_tax_detail_matches_taxable_total?(items, adjustments, tax_details, receipt_attributes)
        total_amount = normalize_amount(receipt_attributes[:total_amount])&.to_i
        return false unless total_amount&.positive?

        usable_tax_details = usable_tax_details_with_gross_amount(tax_details)
        return false unless usable_tax_details.one?

        target_total = single_tax_detail_gross_target_amount(usable_tax_details.first, total_amount)
        return false unless target_total&.positive?

        taxable_entry_total(items, adjustments) == target_total
      end

      def single_tax_detail_gross_target_amount(tax_detail, total_amount)
        amount = tax_detail[:amount]
        net_amount = tax_detail[:net_amount]
        total = total_amount.to_i

        return net_amount.to_i + amount.to_i if net_amount&.positive? && (net_amount.to_i + amount.to_i == total)
        return net_amount.to_i if net_amount&.positive? && net_amount.to_i == total && tax_amount_matches_inclusive_total?(total_amount, amount, tax_detail[:rate])
        return total if tax_amount_matches_inclusive_total?(total_amount, amount, tax_detail[:rate])

        nil
      end

      def taxable_entry_total(items, adjustments)
        item_amount_sum(items) + Array(adjustments).sum do |adjustment|
          next 0 unless taxable_adjustment?(adjustment)

          amount = normalize_amount(adjustment[:amount]).to_i
          adjustment[:sign].to_s == "discount" ? -amount : amount
        end
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
          ReceiptAmountService.apply_rounding(tax, rounding_mode) == amount.to_i
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

      def repair_amount_only_split_items(items, lines)
        source_items = Array(items)
        return source_items if source_items.size < 2

        repaired_items = []
        index = 0
        while index < source_items.size
          current_item = normalized_item_hash(source_items[index])
          following_item = normalized_item_hash(source_items[index + 1])
          amount = amount_only_split_item_amount(current_item)

          if amount.present? &&
              name_only_split_item?(following_item) &&
              item_name_amount_supported_by_lines?(split_item_name(following_item), amount, lines)
            repaired_items << merge_amount_only_split_items(current_item, following_item, amount)
            index += 2
          else
            repaired_items << source_items[index]
            index += 1
          end
        end

        repaired_items
      end

      def normalized_item_hash(item)
        if item.respond_to?(:with_indifferent_access)
          item.with_indifferent_access
        elsif item.respond_to?(:deep_symbolize_keys)
          item.deep_symbolize_keys.with_indifferent_access
        elsif item.respond_to?(:to_h)
          item.to_h.with_indifferent_access
        else
          {}.with_indifferent_access
        end
      end

      def amount_only_split_item_amount(item)
        amount = amount_only_text_amount(split_item_name(item))
        return nil unless amount&.positive?

        amount_values_for_split(item, keys: %i[price line_total]).include?(amount) ? amount : nil
      end

      def name_only_split_item?(item)
        name = split_item_name(item)
        return false if name.blank?
        return false if amount_only_text_amount(name).present?

        amount_values = amount_values_for_split(item)
        amount_values.blank? || amount_values.all?(&:zero?)
      end

      def split_item_name(item)
        item[:suggested_name].presence || item[:confirmed_name].presence || item[:raw_text].to_s.presence
      end

      def amount_values_for_split(item, keys: %i[price line_total original_line_total])
        keys.filter_map do |key|
          normalize_amount(item[key])&.to_i
        end
      end

      def amount_only_text_amount(text)
        source = text.to_s.strip
        return nil if source.blank?
        return nil unless amount_only_text?(source)

        amounts = positive_amounts_from_text(source).uniq
        amounts.one? ? amounts.first : nil
      end

      def amount_only_text?(text)
        source = text.to_s.unicode_normalize(:nfkc).strip
        return false unless source.match?(/[¥￥円\d]/)

        remainder = source.gsub(profile.analysis_fallback_amount_candidate_pattern, "")
        remainder = remainder.gsub(/[¥￥円,，\s　:：*＊\-−+＋().（）\[\]【】]/, "")
        remainder.blank?
      end

      def item_name_amount_supported_by_lines?(name, amount, lines)
        name_compact = compact_item_text(name)
        return false if name_compact.blank?

        Array(lines).each_with_index.any? do |line, index|
          line_compact = compact_item_text(line)
          next false if line_compact.blank?

          if line_compact.include?(name_compact) && positive_amounts_from_text(line).include?(amount.to_i)
            next true
          end

          next false unless line_compact.include?(name_compact)

          adjacent_amount_line_supported?(lines, index, amount)
        end
      end

      def adjacent_amount_line_supported?(lines, index, amount)
        [ index - 1, index + 1 ].any? do |candidate_index|
          next false if candidate_index.negative?

          line = Array(lines)[candidate_index]
          next false if line.blank?
          next false unless amount_only_text?(line)

          positive_amounts_from_text(line).include?(amount.to_i)
        end
      end

      def merge_amount_only_split_items(amount_item, name_item, amount)
        amount_line_total = normalize_amount(amount_item[:line_total]) || amount
        amount_price = normalize_amount(amount_item[:price]) || amount_line_total
        amount_original_line_total = normalize_amount(amount_item[:original_line_total]) || amount_line_total
        review_reasons = merged_split_item_review_reasons(amount_item, name_item)
        confidence = [
          normalize_confidence(amount_item[:confidence]),
          normalize_confidence(name_item[:confidence])
        ].compact.min
        quantity_unit_code = merged_quantity_unit_code(name_item, amount_item)

        amount_item.merge(name_item.compact).merge(
          raw_text: split_item_name(name_item),
          suggested_name: split_item_name(name_item),
          price: amount_price,
          original_line_total: amount_original_line_total,
          line_total: amount_line_total,
          discount_amount: normalize_amount(amount_item[:discount_amount]),
          discount_rate: amount_item[:discount_rate],
          quantity: name_item[:quantity].presence || amount_item[:quantity],
          quantity_unit_code: quantity_unit_code,
          product_code: name_item[:product_code].presence || amount_item[:product_code],
          tax_rate: name_item[:tax_rate].presence || amount_item[:tax_rate],
          tax_rate_confidence: name_item[:tax_rate_confidence].presence || amount_item[:tax_rate_confidence],
          tax_rate_reason: name_item[:tax_rate_reason].presence || amount_item[:tax_rate_reason],
          position_index: amount_item[:position_index] || amount_item[:index] || name_item[:position_index] || name_item[:index],
          index: amount_item[:index] || amount_item[:position_index] || name_item[:index] || name_item[:position_index],
          confidence: confidence,
          needs_review: review_reasons.present?,
          review_reasons: review_reasons
        ).compact
      end

      def merged_split_item_review_reasons(amount_item, name_item)
        (
          normalize_review_reasons(amount_item[:review_reasons]) -
            [ "item_name_uncertain" ] +
          normalize_review_reasons(name_item[:review_reasons])
        ).uniq
      end

      def negative_item_amount?(price:, original_line_total:, line_total:)
        [ price, original_line_total, line_total ].compact.any? { |amount| amount.to_i.negative? }
      end

      def negative_adjustment_source_line_index(raw_text, amount, lines)
        amount = amount.to_i.abs
        return nil unless amount.positive?

        raw_compact = compact_item_text(raw_text)
        Array(lines).each_with_index do |line, index|
          text = line.to_s
          if negative_adjustment_source_text?(text, amount)
            next if raw_compact.present? && !compact_item_text(text).include?(raw_compact)

            return index
          end

          next if raw_compact.blank?
          next unless compact_item_text(text).include?(raw_compact)
          next unless negative_adjustment_context_text?(text) || negative_adjustment_context_text?(raw_text)
          next unless signed_adjustment_amount_near_line?(lines, index, amount)

          return index
        end

        nil
      end

      def negative_adjustment_source_text?(text, amount)
        source = text.to_s
        return false unless source.match?(/[▲△\-−]/)
        return false unless adjustment_amounts_in_text(source).include?(amount.to_i.abs)

        negative_adjustment_context_text?(source)
      end

      def negative_adjustment_source_supported?(source_line_index, raw_text, amount, lines)
        source_text = Array(lines)[source_line_index].to_s
        return true if negative_adjustment_source_text?(source_text, amount)
        return false unless negative_adjustment_context_text?(source_text) || negative_adjustment_context_text?(raw_text)

        signed_adjustment_amount_near_line?(lines, source_line_index, amount)
      end

      def negative_adjustment_context_text?(text)
        text.to_s.match?(profile.analysis_negative_adjustment_context_pattern)
      end

      def signed_adjustment_amount_near_line?(lines, source_line_index, amount)
        lines_around(lines, source_line_index, before: 1, after: 1).any? do |line|
          source = line.to_s
          source.match?(/[▲△\-−]/) && adjustment_amounts_in_text(source).include?(amount.to_i.abs)
        end
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

      def compact_adjustment_evidence_text(value)
        value.to_s.unicode_normalize(:nfkc).gsub(/\s+/, "")
      end

      def lines_around(lines, index, before:, after:)
        return [] if index.nil?
        return [] if index.negative?

        start_index = [ index - before, 0 ].max
        end_index = [ index + after, Array(lines).length - 1 ].min
        Array(lines)[start_index..end_index].to_a
      end

      def adjustment_amounts_in_text(text)
        MoneyTokenClassifier.money_matches(
          text: text,
          money_pattern: profile.analysis_adjustment_amount_candidate_pattern,
          profile: profile,
          allow_bare_money: true
        ).map { |token| token[:amount] }
      end

      def default_adjustment_sign(kind)
        %w[service_charge late_night_charge delivery_fee bag_fee handling_fee].include?(ReceiptAdjustment.normalize_kind(kind)) ? "surcharge" : "discount"
      end

      def adjustment_label_for(kind, label, source_text)
        normalized_label = label.to_s.strip.presence
        return normalized_label unless kind.to_s == "return_refund"

        source_label = adjustment_source_label_without_amount(source_text)
        return normalized_label if source_label.blank?
        return source_label if normalized_label.blank?
        return source_label if source_label.include?(normalized_label) && source_label.length > normalized_label.length

        normalized_label
      end

      def adjustment_source_text_for(adjustment, source_line_index, lines)
        explicit_source = adjustment[:source_text].to_s.strip.presence
        line_source = Array(lines)[source_line_index].to_s.strip.presence unless source_line_index.nil?
        if generic_return_refund_label?(explicit_source) && line_source.present? && line_source.length > explicit_source.length
          return line_source
        end

        explicit_source || line_source
      end

      def generic_return_refund_label?(text)
        text.to_s.unicode_normalize(:nfkc).strip.match?(profile.analysis_generic_return_refund_label_pattern)
      end

      def adjustment_source_label_without_amount(source_text)
        source_text.to_s
          .unicode_normalize(:nfkc)
          .sub(/\s*[▲△\-−]?\s*[¥￥]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d{1,3}(?:\s+\d{3})+|\d+)(?:円)?\s*\z/, "")
          .strip
          .presence
      end

      def infer_ocr_adjustment_kind(source_text, sign)
        text = source_text.to_s
        return "return_refund" if text.match?(profile.analysis_return_refund_kind_pattern)
        return "coupon" if text.match?(profile.analysis_coupon_kind_pattern)
        return "receipt_discount" if cashless_reward_adjustment_text?(text)
        return "point_usage" if text.match?(profile.analysis_point_usage_kind_pattern)
        return "receipt_discount" if text.match?(profile.analysis_receipt_discount_kind_pattern)
        return "late_night_charge" if text.match?(profile.analysis_late_night_charge_kind_pattern)
        return "service_charge" if text.match?(profile.analysis_service_charge_kind_pattern)
        return "delivery_fee" if text.match?(profile.analysis_delivery_fee_kind_pattern)
        return "bag_fee" if text.match?(profile.analysis_bag_fee_kind_pattern)
        return "handling_fee" if text.match?(profile.analysis_handling_fee_kind_pattern) && sign == "surcharge"

        "other"
      end

      def cashless_reward_adjustment_text?(text)
        text.to_s.match?(profile.analysis_cashless_reward_adjustment_pattern)
      end

      def infer_tax_rate_from_text(text)
        match = text.to_s.unicode_normalize(:nfkc).match(profile.analysis_tax_rate_hint_pattern)
        return nil unless match

        BigDecimal(match[1]) / 100
      end

      def non_taxable_item_text?(raw_text, item)
        text = [
          raw_text,
          item[:suggested_name],
          item[:confirmed_name],
          item[:name]
        ].compact.join(" ").unicode_normalize(:nfkc)

        text.match?(profile.analysis_non_taxable_text_pattern)
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

      def merge_items(candidate_items, ai_items, lines: [], ai_name_completion_enabled: nil)
        normalized_candidate_items = Array(candidate_items).map do |item|
          item_hash = item.respond_to?(:deep_symbolize_keys) ? item.deep_symbolize_keys : {}
          item_hash.with_indifferent_access
        end
        normalized_ai_items = normalize_items(ai_items)
        raw_ai_indexes = raw_ai_item_indexes(normalized_ai_items)
        index_mode = ai_item_index_mode(raw_ai_indexes, normalized_candidate_items.size)
        index_issues = ai_item_index_issues(raw_ai_indexes, normalized_candidate_items.size, index_mode)

        ai_items_by_index = normalized_ai_items.each_with_object({}) do |item, result|
          ai_index = normalize_item_index(
            item[:index] || item["index"] || item[:position_index] || item["position_index"]
          )
          target_index = ai_item_target_index(ai_index, normalized_candidate_items.size, index_mode)
          next if target_index.nil?

          result[target_index] ||= item
        end

        normalized_candidate_items.each_with_index.map do |candidate_item, candidate_index|
          ai_item = ai_items_by_index[candidate_index] || {}.with_indifferent_access
          merged_item = candidate_item.merge(ai_item.compact)
          index_review_needed = ai_item_index_review_needed?(candidate_index, index_issues)
          review_reasons = normalize_review_reasons(ai_item[:review_reasons].presence || candidate_item[:review_reasons])
          review_reasons |= [ "item_name_uncertain" ] if index_review_needed
          suggested_name = suggested_item_name_for(
            candidate_item,
            ai_item,
            lines: lines,
            ai_name_completion_enabled: ai_name_completion_enabled
          )
          name_completion_review_needed = ai_suggested_name_rejected?(
            candidate_item,
            ai_item,
            suggested_name,
            lines: lines,
            ai_name_completion_enabled: ai_name_completion_enabled
          )
          review_reasons |= [ "item_name_uncertain" ] if name_completion_review_needed

          # quantity_unit_code / product_code はOCR優先で保持する。
          quantity_unit_code = merged_quantity_unit_code(candidate_item, ai_item)
          merged_item.merge(
            suggested_name: suggested_name,
            category: ai_item[:category].presence || candidate_item[:category],
            needs_review: (index_review_needed || name_completion_review_needed) ? true : (ai_item.key?(:needs_review) ? ai_item[:needs_review] : nil),
            review_reasons: review_reasons,
            quantity_unit_code: quantity_unit_code,
            product_code: ai_item[:product_code].presence || candidate_item[:product_code],
            tax_rate: ai_item[:tax_rate].presence || candidate_item[:tax_rate],
            tax_rate_confidence: ai_item[:tax_rate_confidence],
            tax_rate_reason: ai_item[:tax_rate_reason],
            original_line_total: candidate_item[:original_line_total],
            discount_amount: candidate_item[:discount_amount],
            discount_rate: candidate_item[:discount_rate],
            position_index: normalize_item_index(candidate_item[:position_index] || candidate_item["position_index"]) || candidate_index
          )
        end
      end

      def suggested_item_name_for(candidate_item, ai_item, lines:, ai_name_completion_enabled:)
        candidate_name = candidate_item[:suggested_name]
        ai_name = ai_item[:suggested_name].presence

        return candidate_name if ai_name_completion_enabled == false
        return candidate_name if ai_name.blank?
        return ai_name unless ai_name_completion_enabled == true

        ai_suggested_name_supported?(candidate_item, ai_name, lines) ? ai_name : candidate_name
      end

      def ai_suggested_name_rejected?(candidate_item, ai_item, suggested_name, lines:, ai_name_completion_enabled:)
        return false unless ai_name_completion_enabled == true

        ai_name = ai_item[:suggested_name].presence
        return false if ai_name.blank?

        suggested_name != ai_name && !ai_suggested_name_supported?(candidate_item, ai_name, lines)
      end

      def ai_suggested_name_supported?(candidate_item, ai_name, lines)
        ai_text = compact_item_text(ai_name)
        return false if ai_text.blank?

        item_name_evidence_texts(candidate_item, lines).any? do |evidence|
          evidence_text = compact_item_text(evidence)
          next false if evidence_text.blank?
          next false if evidence_text.match?(/\A[¥￥$€£]?[+-]?\d[\d,]*(?:\.\d+)?\z/)

          ai_text.include?(evidence_text) || evidence_text.include?(ai_text)
        end
      end

      def item_name_evidence_texts(candidate_item, lines)
        evidence = [
          candidate_item[:raw_text],
          candidate_item[:suggested_name],
          candidate_item[:confirmed_name],
          candidate_item[:name],
          candidate_item[:source_text]
        ]
        source_indexes = item_line_indexes(candidate_item, lines)
        evidence.concat(source_indexes.map { |index| Array(lines)[index] })
        evidence.compact_blank
      end

      def raw_ai_item_indexes(ai_items)
        Array(ai_items).filter_map do |item|
          normalize_item_index(item[:index] || item["index"] || item[:position_index] || item["position_index"])
        end
      end

      def ai_item_index_mode(indexes, candidate_count)
        normalized_indexes = Array(indexes)
        return :zero_based if normalized_indexes.blank? || normalized_indexes.include?(0)
        return :one_based if normalized_indexes.all? { |index| index.positive? && index <= candidate_count.to_i }

        :zero_based
      end

      def ai_item_index_issues(indexes, candidate_count, index_mode)
        target_indexes = Array(indexes).map do |index|
          ai_item_target_index(index, candidate_count, index_mode)
        end
        grouped = target_indexes.compact.group_by(&:itself)

        {
          duplicate_indexes: grouped.filter_map { |index, values| index if values.size > 1 },
          out_of_range: target_indexes.any?(&:nil?)
        }
      end

      def ai_item_target_index(index, candidate_count, index_mode)
        return nil if index.nil? || index.negative? || candidate_count.to_i <= 0

        target_index = index_mode == :one_based ? index - 1 : index
        return nil if target_index.negative? || target_index >= candidate_count.to_i

        target_index
      end

      def ai_item_index_review_needed?(candidate_index, index_issues)
        duplicate_indexes = Array(index_issues[:duplicate_indexes])
        duplicate_indexes.include?(candidate_index) ||
          (candidate_index.zero? && index_issues[:out_of_range])
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
            quantity_unit_code: ReceiptQuantityUnit.default_code,
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

        return true if compact_text.match?(profile.analysis_fallback_non_item_keyword_pattern)
        return true if compact_text.match?(profile.analysis_fallback_tax_target_non_item_pattern)
        return true if text.match?(profile.analysis_point_payment_line_pattern) || text.match?(profile.analysis_point_display_line_pattern)
        return true if compact_text.match?(profile.analysis_fallback_tax_amount_line_pattern)
        return true if text.match?(profile.analysis_fallback_reference_line_pattern)
        return true if text.match?(/\bT\d{13}\b/i)
        return true if text.match?(profile.analysis_fallback_date_time_line_pattern)
        return true if text.match?(FALLBACK_URL_OR_EMAIL_PATTERN)
        return true if text.match?(profile.analysis_fallback_payment_line_pattern)

        false
      end

      def adjustment_source_noise_line?(line, _amount)
        text = line.to_s.unicode_normalize(:nfkc).strip
        return false if text.blank?
        return true if fallback_payment_amount_noise_line?(text)

        false
      end

      def fallback_amount_source(line)
        line.to_s.sub(/\s*[x×]\s*\d+(?:\.\d+)?\s*\z/i, "")
      end

      def rightmost_fallback_amount_candidate(line)
        source = fallback_amount_source(line)
        matches = source.to_enum(:scan, profile.analysis_fallback_amount_candidate_pattern).map { Regexp.last_match }
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

      def reconcile_payment_method_with_payments(current_method, payments, adjustments: [], lines: [], receipt_total: nil)
        current = normalize_detected_payment_method(current_method)
        voucher_payment_present = Array(payments).any? { |payment| voucher_payment_text?(payment[:method]) }
        detected_from_payments = detect_payment_method_from_payments(payments)
        if voucher_payment_present
          return "other" if cash_payments_are_settlement_difference?(payments, lines)
          return detected_from_payments if detected_from_payments.present?

          return "other"
        end

        return current unless payment_sum_matches_total?(payments, receipt_total) ||
          payment_sum_matches_final_payment_total?(payments, receipt_total, adjustments)
        return current unless payment_method_should_follow_payments?(current, detected_from_payments)

        detected_from_payments
      end

      def payment_sum_matches_final_payment_total?(payments, receipt_total, adjustments)
        total = normalize_amount(receipt_total)&.to_i
        return false unless total&.positive?

        payment_adjustment_total = Array(adjustments).sum do |adjustment|
          classification = ReceiptAmountService.adjustment_classification(adjustment)
          classification[:effect] == :payment_adjustment ? classification[:signed_amount].to_i : 0
        end
        return false if payment_adjustment_total.zero?

        Array(payments).present? &&
          Array(payments).sum { |payment| payment[:amount].to_i } == total + payment_adjustment_total
      end

      def payment_method_should_follow_payments?(current, detected_from_payments)
        return false if detected_from_payments.blank?
        return true if current.blank?
        return true if current == "cash" && detected_from_payments != "cash"
        return true if current == "credit_card" && detected_from_payments == "e_money"

        current == "e_money" && detected_from_payments == "qr_payment"
      end

      def cash_payments_are_settlement_difference?(payments, lines)
        non_voucher_payments = Array(payments).reject { |payment| voucher_payment_text?(payment[:method]) }
        return false if non_voucher_payments.blank?
        return false unless non_voucher_payments.all? do |payment|
          normalize_detected_payment_method(Analysis::ReceiptFallbackPatterns.detect_payment_method(payment[:method])) == "cash"
        end

        deposit_amount = settlement_amount_from_lines(lines, profile.analysis_cash_deposit_label_pattern)
        change_amount = settlement_amount_from_lines(lines, profile.analysis_cash_change_label_pattern)
        return false unless deposit_amount&.positive? && !change_amount.nil?

        non_voucher_payments.sum { |payment| payment[:amount].to_i } == deposit_amount - change_amount
      end

      def detect_payment_method_from_payments(payments)
        detected_methods = Array(payments).filter_map do |payment|
          normalized_payment = payment.respond_to?(:deep_symbolize_keys) ? payment.deep_symbolize_keys : {}
          method_text = normalized_payment[:method]
          next if method_text.blank?
          next if method_text.match?(profile.analysis_non_representative_payment_pattern)

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

        profile.analysis_purchased_at_date_only_patterns.any? { |pattern| text.match?(pattern) }
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
        return false if text.match?(profile.analysis_purchase_time_exclusion_pattern)

        extract_time_expression(text).present?
      end

      def extract_time_expression(text)
        extract_time_expression_detail(text)&.fetch(:time)
      end

      def extract_time_expression_detail(text)
        match = text.to_s.match(profile.analysis_purchase_time_expression_pattern)
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

      def normalize_quantity_unit_code(value)
        ReceiptQuantityUnit.normalize(value)
      end

      def merged_quantity_unit_code(primary_item, fallback_item)
        primary = primary_item[:quantity_unit_code]
        fallback = fallback_item[:quantity_unit_code]

        normalize_quantity_unit_code(primary.presence || fallback)
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
