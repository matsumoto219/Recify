module Ai
  class ResultTemplate
    class << self
      def success(receipt_attributes: {}, receipt_items_attributes: [], receipt_adjustments_attributes: [], needs_review: false, review_reasons: [], meta: {})
        {
          success: true,
          needs_review: needs_review,
          receipt_attributes: receipt_attributes || {},
          receipt_items_attributes: Array(receipt_items_attributes),
          receipt_adjustments_attributes: Array(receipt_adjustments_attributes),
          review_reasons: Array(review_reasons),
          error_code: nil,
          meta: meta || {}
        }
      end

      def error(error_code:, needs_review: true, receipt_attributes: {}, receipt_items_attributes: [], receipt_adjustments_attributes: [], review_reasons: [], meta: {})
        {
          success: false,
          needs_review: needs_review,
          receipt_attributes: receipt_attributes || {},
          receipt_items_attributes: Array(receipt_items_attributes),
          receipt_adjustments_attributes: Array(receipt_adjustments_attributes),
          review_reasons: Array(review_reasons),
          error_code: error_code,
          meta: meta || {}
        }
      end
    end
  end
end
