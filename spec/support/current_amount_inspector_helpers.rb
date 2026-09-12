module CurrentAmountInspectorHelpers
  def current_amount_profile
    candidate = {
      "candidate_id" => "items_as_tax_included/floor/per_tax_rate_group",
      "basis" => "items_as_tax_included",
      "rounding_mode" => "floor",
      "rounding_scope" => "per_tax_rate_group",
      "subtotal" => 1000,
      "tax" => 100,
      "purchase_total" => 1100,
      "final_payment_total" => 1100,
      "score" => -1,
      "score_breakdown" => { "receipt_total_delta" => 0, "basis_penalty" => -1 },
      "hard_reject_reasons" => [],
      "warnings" => [ "price_tax_inclusion_uncertain" ],
      "evidence" => [ { "source" => "receipt_items", "index" => 0, "gross_amount" => 1100 } ],
      "computed_items" => [ { "price" => 1100, "quantity" => "1.0", "line_total" => 1100, "tax_rate" => "0.1" } ]
    }
    {
      "schema_version" => 1,
      "context" => "analysis",
      "profile" => { "item_amount_basis" => "line_total_as_recorded", "tax_rounding_mode" => "floor" },
      "rounding_mode" => { "tax" => "floor", "discount" => "round" },
      "computed" => { "total_amount" => 1100, "subtotal_amount" => 1000, "tax_amount" => 100 },
      "resolved" => { "total_amount" => 1100, "subtotal_amount" => 1000, "tax_amount" => 100 },
      "score" => -1,
      "selected_candidate_status" => "accepted",
      "safe_to_auto_complete" => false,
      "warnings" => [ "price_tax_inclusion_uncertain" ],
      "blocking_mismatch_codes" => [],
      "warning_mismatch_codes" => [ "PRICE_TAX_INCLUSION_UNCERTAIN" ],
      "amount_engine" => {
        "schema_version" => 1,
        "selected_candidate_id" => candidate.fetch("candidate_id"),
        "selected_candidate_status" => "accepted",
        "no_safe_candidate" => false,
        "selected_candidate" => candidate,
        "candidates" => [
          candidate.deep_dup,
          candidate.deep_dup.merge(
            "candidate_id" => "printed_tax_details_raw_sum/floor",
            "basis" => "printed_tax_details_raw_sum",
            "score" => 100_000,
            "hard_reject_reasons" => [ "tax_details_double_counted" ]
          )
        ]
      }
    }
  end
end
