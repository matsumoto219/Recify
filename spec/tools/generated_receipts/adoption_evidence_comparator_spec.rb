# frozen_string_literal: true

require "json"
require_relative "../../../tools/generated_receipts"

RSpec.describe GeneratedReceipts::AdoptionEvidence::Comparator do
  def evidence_case
    {
      "case_id" => "g123_adoption_gross_no_total",
      "intent" => "item-local gross reference pricing without a printed total",
      "expected" => {},
      "render" => { "custom_lines" => [ "SYNTHETIC RECEIPT", "税込 120円/100g", "250g" ] },
      "degradation" => { "enabled" => false, "profile" => nil },
      "ground_truth" => {
        "defined_before_image_generation" => true,
        "items" => [
          {
            "item_index" => 0,
            "evidence_class" => "reference_pricing",
            "printed_line_total" => nil,
            "existing_authority" => false,
            "same_item_evidence" => true,
            "dimension_compatible" => true,
            "item_local_tax_rate" => nil,
            "tax_rounding_mode" => "round",
            "tax_rate_conflict" => false,
            "package_conflict" => false,
            "discount_conflict" => false,
            "deterministic_projection" => true,
            "projection_within_bounds" => true,
            "projected_gross_line_total" => 300,
            "adoption_outcome" => "eligible",
            "adoption_blocking_reasons" => []
          }
        ],
        "expected_candidates" => [ candidate_summary ],
        "expected_associations" => [ association ]
      }
    }
  end

  def candidate_summary
    {
      "item_index" => 0,
      "validation_state" => "valid",
      "rejection_reasons" => [],
      "reference_price_amount" => "120",
      "reference_quantity" => "100",
      "reference_unit_code" => "gram",
      "purchased_quantity" => "250",
      "purchased_unit_code" => "gram",
      "reference_price_tax_inclusion" => "gross",
      "projected_line_total" => 300,
      "printed_line_total" => nil,
      "rounding_matches" => []
    }
  end

  def association
    { "candidate_index" => 0, "item_index" => 0, "evidence_scope" => "same_item" }
  end

  it "compares an offline provider candidate summary and explicit association map" do
    result = described_class.call(
      evidence_case,
      candidate_summary: [ candidate_summary ],
      associations: [ association ]
    )

    aggregate_failures do
      expect(result).to be_pass
      expect(result.diffs).to eq([])
      expect(result.metrics).to include(
        total_items: 1,
        reference_pricing_items: 1,
        candidate_extracted: 1,
        valid: 1,
        false_association: 0,
        package_false_positive: 0,
        tax_basis_determined: 1,
        no_total_eligible_candidates: 1
      )
    end
  end

  it "reports candidate drift using only allowlisted summary fields" do
    actual = candidate_summary.merge(
      "validation_state" => "ambiguous",
      "rejection_reasons" => [ "ambiguous_tax_inclusion" ]
    )

    result = described_class.call(
      evidence_case,
      candidate_summary: [ actual ],
      associations: [ association ]
    )

    aggregate_failures do
      expect(result.status).to eq("FAIL")
      expect(result.diffs).to include(
        hash_including(path: "candidate_summary[0].validation_state", severity: "FAIL")
      )
      expect(result.metrics[:no_total_eligible_candidates]).to eq(0)
      expect(JSON.generate(result.diffs)).not_to include("SYNTHETIC RECEIPT", "税込 120円/100g")
    end
  end

  it "redacts amount and quantity values from candidate drift diffs" do
    actual = candidate_summary.merge(
      "reference_price_amount" => "121",
      "reference_quantity" => "125",
      "purchased_quantity" => "375",
      "projected_line_total" => 363,
      "printed_line_total" => "363"
    )

    result = described_class.call(
      evidence_case,
      candidate_summary: [ actual ],
      associations: [ association ]
    )
    value_paths = %w[
      reference_price_amount
      reference_quantity
      purchased_quantity
      projected_line_total
      printed_line_total
    ].map { |field| "candidate_summary[0].#{field}" }
    value_diffs = result.diffs.select { |diff| value_paths.include?(diff.fetch(:path)) }
    serialized = JSON.generate(value_diffs)

    aggregate_failures do
      expect(result.status).to eq("FAIL")
      expect(value_diffs.map { |diff| diff.fetch(:path) }).to match_array(value_paths)
      expect(value_diffs).to all(include(expected: "[redacted]", actual: "[redacted]"))
      %w[120 121 100 125 250 375 300 363].each do |sensitive_value|
        expect(serialized).not_to include(sensitive_value)
      end
    end
  end

  it "does not count a candidate with a provider printed total as no-total eligible" do
    actual = candidate_summary.merge("printed_line_total" => 300)

    result = described_class.call(
      evidence_case,
      candidate_summary: [ actual ],
      associations: [ association ]
    )

    aggregate_failures do
      expect(result.status).to eq("FAIL")
      expect(result.metrics[:no_total_eligible_candidates]).to eq(0)
    end
  end

  it "counts a provider association to package content as a false positive" do
    data = evidence_case
    item = data.dig("ground_truth", "items", 0)
    item.merge!(
      "evidence_class" => "package_content",
      "deterministic_projection" => false,
      "projected_gross_line_total" => nil,
      "package_conflict" => true,
      "adoption_outcome" => "unsupported",
      "adoption_blocking_reasons" => [ "candidate_count_not_one", "package_conflict" ]
    )
    data["ground_truth"]["expected_candidates"] = []
    data["ground_truth"]["expected_associations"] = []

    result = described_class.call(
      data,
      candidate_summary: [ candidate_summary ],
      associations: [ association ]
    )

    expect(result.metrics).to include(package_false_positive: 1)
  end

  it "fails closed without echoing malformed provider content" do
    sensitive = "private receipt raw text\ncard-token"

    result = described_class.call(
      evidence_case,
      candidate_summary: [ { "raw_text" => sensitive } ],
      associations: [ association.merge("raw_span" => sensitive) ]
    )

    aggregate_failures do
      expect(result.status).to eq("FAIL")
      expect(result.diffs).to contain_exactly(
        hash_including(path: "comparison_input", severity: "FAIL")
      )
      expect(JSON.generate(result.diffs)).not_to include(sensitive, "card-token")
    end
  end


  it "rejects raw fields even when all summary fields are otherwise valid" do
    sensitive = "private provider payload"
    actual = candidate_summary.merge(
      "raw_text" => sensitive,
      "provider_raw_response" => { "content" => sensitive }
    )

    result = described_class.call(
      evidence_case,
      candidate_summary: [ actual ],
      associations: [ association ]
    )

    aggregate_failures do
      expect(result.status).to eq("FAIL")
      expect(result.diffs).to contain_exactly(
        hash_including(path: "comparison_input", severity: "FAIL")
      )
      expect(JSON.generate(result.diffs)).not_to include(sensitive)
    end
  end
end
