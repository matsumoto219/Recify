require_relative "current_amount_inspector_helpers"

module RunAmountInspectorHelpers
  include CurrentAmountInspectorHelpers

  def run_amount_snapshot
    profile = current_amount_profile
    engine = profile.fetch("amount_engine")
    engine["selected_basis"] = engine.fetch("selected_candidate").fetch("basis")
    [ engine.fetch("selected_candidate"), *engine.fetch("candidates") ].each do |candidate|
      candidate.merge!("purchase_adjustment_total" => 0, "payment_adjustment_total" => 0)
    end
    result = {
      context: :analysis,
      rounding_mode: { tax: :floor, discount: :round },
      computed: { total: 1100, subtotal: 1000, tax: 100 },
      resolved: { total: 1100, subtotal: 1000, tax: 100 },
      calculation_profile: profile.fetch("profile"),
      calculation_profile_score: -1,
      needs_review: true,
      review_reasons: [ "price_tax_inclusion_uncertain" ],
      warnings: [ "price_tax_inclusion_uncertain" ],
      blocking_mismatch_codes: [],
      warning_mismatch_codes: [ "PRICE_TAX_INCLUSION_UNCERTAIN" ],
      selected_candidate_status: "accepted",
      safe_to_auto_complete: false,
      amount_engine: profile.fetch("amount_engine")
    }
    Receipts::Processing::Contracts::AmountCalculationRunSnapshot.build(
      amount_result: result,
      saved_profile: profile,
      receipt_summary: { status: "review_needed", total_amount: 1100, subtotal_amount: 1000, tax_amount: 100 },
      limits: { "max_bytes" => 131_072, "computed_items" => 100, "evidence" => 200, "candidates" => 3 }
    )
  end
end
