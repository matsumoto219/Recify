class Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator
  class << self
    def ocr(snapshot)
      snapshot = normalized_hash(snapshot)
      return nil if snapshot.blank?

      proposal = Receipts::Processing::Contracts::ReferencePricingAdoptionProposal.from_snapshot(
        snapshot.dig(:adoption_proposals, :reference_pricing),
        ocr_snapshot: snapshot
      )
      tax_details = Receipts::Processing::Contracts::ReferencePricingTaxDetailStructuralEvidenceSet.from_snapshot(
        snapshot.dig(:adoption_proposals, :reference_pricing_tax_details),
        ocr_snapshot: snapshot
      )
      item_calculation_modes = Receipts::Processing::Contracts::ItemCalculationModeProposalSet.from_snapshot(
        snapshot.dig(:adoption_proposals, :item_calculation_modes),
        ocr_snapshot: snapshot
      )
      adoption_proposals = {}
      adoption_proposals["reference_pricing"] = proposal if proposal
      adoption_proposals["reference_pricing_tax_details"] = tax_details if tax_details
      adoption_proposals["item_calculation_modes"] = item_calculation_modes if item_calculation_modes.present?

      {
        schema_version: snapshot[:schema_version] ==
          Receipts::Processing::Runs::SnapshotBuilder::OCR_RESULT_SCHEMA_VERSION ?
            snapshot[:schema_version] : nil,
        success: snapshot[:success] == true,
        lines: Array(snapshot[:lines]).map(&:to_s),
        case_preserved_lines: Array(snapshot[:case_preserved_lines]).map(&:to_s),
        candidates: rehydrate_ocr_candidates(snapshot),
        candidate_counts: normalized_hash(snapshot[:candidate_counts]).to_h,
        error_code: snapshot[:error_code].presence,
        meta: normalized_hash(snapshot[:meta]).to_h,
        truncated: rehydrate_ocr_truncation(snapshot[:truncated]),
        adoption_proposals: adoption_proposals.presence
      }.compact
    end

    def ai(snapshot)
      snapshot = normalized_hash(snapshot)
      return nil if snapshot.blank?

      receipt_items_attributes = rehydrate_ai_items(snapshot[:receipt_items_attributes])
      item_category_uncertain = receipt_items_attributes.any? do |item|
        Array(item["review_reasons"] || item[:review_reasons]).include?("item_category_uncertain")
      end
      review_reasons = Array(snapshot[:review_reasons])
      review_reasons |= [ "item_category_uncertain" ] if item_category_uncertain

      {
        success: snapshot[:success] == true,
        error_code: snapshot[:error_code].presence,
        needs_review: snapshot[:needs_review] == true || item_category_uncertain,
        review_reasons: review_reasons,
        receipt_attributes: rehydrate_ai_receipt_attributes(snapshot[:receipt_attributes]),
        receipt_items_attributes: receipt_items_attributes,
        receipt_adjustments_attributes: rehydrate_ai_adjustments(snapshot[:receipt_adjustments_attributes]),
        attribute_counts: normalized_hash(snapshot[:attribute_counts]).to_h,
        meta: normalized_hash(snapshot[:meta]).to_h
      }.compact
    end

    private

    def rehydrate_ocr_candidates(snapshot)
      candidates = normalized_hash(snapshot[:candidates]).dup
      basis = candidates.delete(:tax_detail_amount_basis)
      counts = normalized_hash(normalized_hash(snapshot[:candidate_counts])[:tax_details])
      count = Array(candidates[:tax_details]).size
      if basis == "net" && count.positive? &&
          normalized_hash(snapshot[:truncated])[:tax_details] != true &&
          counts[:actual_count] == count && counts[:snapshot_count] == count
        candidates[:tax_detail_amount_basis] = "net"
      end
      candidates.to_h
    end

    def rehydrate_ocr_truncation(value)
      normalized = normalized_hash(value)
      %w[
        lines case_preserved_lines items payments tax_details adjustment_candidates
        reference_pricing_candidates item_calculation_mode_candidates
      ].each_with_object({}) do |key, snapshot|
        snapshot[key] = normalized[key] == true if normalized.key?(key)
      end
    end

    def rehydrate_ai_receipt_attributes(value)
      normalized_hash(value).to_h
    end

    def rehydrate_ai_items(value)
      Array(value).map do |item|
        normalized = normalized_hash(item)
        raw_category = normalized[:category].to_s.strip.presence
        category = raw_category if ReceiptItem::CATEGORIES.include?(raw_category)
        category_invalid = raw_category.present? && category.nil?
        review_reasons = Array(normalized[:review_reasons])
        review_reasons |= [ "item_category_uncertain" ] if category_invalid

        normalized[:category] = category
        normalized.delete(:category) if category.nil?
        if review_reasons.include?("item_category_uncertain")
          normalized[:needs_review] = true
          normalized[:review_reasons] = review_reasons
        end
        normalized.to_h
      end
    end

    def rehydrate_ai_adjustments(value)
      Array(value).map do |adjustment|
        normalized_hash(adjustment).to_h
      end
    end

    def normalized_hash(value)
      return value.with_indifferent_access if value.respond_to?(:with_indifferent_access)

      {}.with_indifferent_access
    end
  end
end
