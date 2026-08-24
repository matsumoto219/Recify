module Ai
  class ResultTemplate
    class << self
      def success(receipt_attributes: {}, receipt_items_attributes: [], receipt_adjustments_attributes: [], needs_review: false, review_reasons: [], meta: {}, reference_pricing_selection: nil)
        result = {
          success: true,
          needs_review: needs_review,
          receipt_attributes: receipt_attributes || {},
          receipt_items_attributes: Array(receipt_items_attributes),
          receipt_adjustments_attributes: Array(receipt_adjustments_attributes),
          review_reasons: Array(review_reasons),
          error_code: nil,
          meta: meta || {}
        }
        result[:reference_pricing_selection] = reference_pricing_selection if reference_pricing_selection.present?
        result
      end

      def error(error_code:, needs_review: true, receipt_attributes: {}, receipt_items_attributes: [], receipt_adjustments_attributes: [], review_reasons: [], meta: {}, reference_pricing_selection: nil)
        result = {
          success: false,
          needs_review: needs_review,
          receipt_attributes: receipt_attributes || {},
          receipt_items_attributes: Array(receipt_items_attributes),
          receipt_adjustments_attributes: Array(receipt_adjustments_attributes),
          review_reasons: Array(review_reasons),
          error_code: error_code,
          meta: meta || {}
        }
        result[:reference_pricing_selection] = reference_pricing_selection if reference_pricing_selection.present?
        result
      end
    end
  end
end
