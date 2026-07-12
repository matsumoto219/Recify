class Receipts::Processing::Pipeline::FinalizeStep::SnapshotRehydrator
  class << self
    def ocr(snapshot)
      snapshot = normalized_hash(snapshot)
      return nil if snapshot.blank?

      {
        success: snapshot[:success] == true,
        lines: Array(snapshot[:lines]).map(&:to_s),
        case_preserved_lines: Array(snapshot[:case_preserved_lines]).map(&:to_s),
        candidates: normalized_hash(snapshot[:candidates]).to_h,
        candidate_counts: normalized_hash(snapshot[:candidate_counts]).to_h,
        error_code: snapshot[:error_code].presence,
        meta: normalized_hash(snapshot[:meta]).to_h
      }.compact
    end

    def ai(snapshot)
      snapshot = normalized_hash(snapshot)
      return nil if snapshot.blank?

      {
        success: snapshot[:success] == true,
        error_code: snapshot[:error_code].presence,
        needs_review: snapshot[:needs_review] == true,
        review_reasons: Array(snapshot[:review_reasons]),
        receipt_attributes: rehydrate_ai_receipt_attributes(snapshot[:receipt_attributes]),
        receipt_items_attributes: rehydrate_ai_items(snapshot[:receipt_items_attributes]),
        receipt_adjustments_attributes: rehydrate_ai_adjustments(snapshot[:receipt_adjustments_attributes]),
        attribute_counts: normalized_hash(snapshot[:attribute_counts]).to_h,
        meta: normalized_hash(snapshot[:meta]).to_h
      }.compact
    end

    private

    def rehydrate_ai_receipt_attributes(value)
      normalized_hash(value).to_h
    end

    def rehydrate_ai_items(value)
      Array(value).map do |item|
        normalized_hash(item).to_h
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
