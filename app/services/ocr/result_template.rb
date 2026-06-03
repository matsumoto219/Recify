module Ocr
  module ResultTemplate
    module_function

    def error_result(error_code:, provider:, model_id: nil)
      {
        success: false,
        raw_text: "",
        lines: [],
        candidates: empty_candidates.deep_dup,
        error_code: error_code,
        meta: {
          provider: provider,
          model_id: model_id,
          raw_response_included: false
        }
      }
    end

    def empty_candidates
      {
        store_name: nil,
        store_address: nil,
        store_address_components: {},
        store_phone_number: nil,
        purchased_at_text: nil,
        total_amount: nil,
        subtotal_amount: nil,
        tax_amount: nil,
        tax_rate: nil,
        tip_amount: nil,
        currency_code: nil,
        country_region: nil,
        receipt_type: nil,
        payments: [],
        tax_details: [],
        adjustment_candidates: [],
        payment_method_text: nil,
        items: [],
        review_reasons: [],
        confidence_summary: empty_confidence_summary
      }
    end

    def empty_confidence_summary
      {
        merchant_name: nil,
        purchased_at: nil,
        total_amount: nil,
        subtotal_amount: nil,
        tax_amount: nil,
        tax_rate: nil,
        items_average: nil,
        overall: nil
      }
    end
  end
end
