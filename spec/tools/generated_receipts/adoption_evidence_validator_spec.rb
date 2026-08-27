# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "../../../tools/generated_receipts"

RSpec.describe GeneratedReceipts::AdoptionEvidence::Validator do
  def evidence_case
    {
      "case_id" => "g123_adoption_gross_no_total",
      "intent" => "item-local gross reference pricing without a printed total",
      "expected" => {},
      "render" => {
        "paper_width" => "58mm",
        "custom_lines" => [ "SYNTHETIC RECEIPT", "税込 120円/100g", "250g" ]
      },
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
        "expected_candidates" => [
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
        ],
        "expected_associations" => [
          { "candidate_index" => 0, "item_index" => 0, "evidence_scope" => "same_item" }
        ]
      }
    }
  end

  def deep_dup(value)
    JSON.parse(JSON.generate(value))
  end

  let(:schema) do
    JSON.parse(
      File.read(
        File.join(
          GeneratedReceipts::ROOT,
          "adoption_evidence_case_schema.json"
        )
      )
    )
  end

  it "keeps the dedicated schema required fields and enums in parity with the validator" do
    ground_truth_schema = schema.dig("properties", "ground_truth")
    item_schema = ground_truth_schema.dig("properties", "items", "items")
    candidate_schema = ground_truth_schema.dig("properties", "expected_candidates", "items")
    association_schema = ground_truth_schema.dig("properties", "expected_associations", "items")

    aggregate_failures do
      expect(schema["required"]).to match_array(described_class::TOP_LEVEL_KEYS)
      expect(ground_truth_schema["required"]).to match_array(described_class::GROUND_TRUTH_KEYS)
      expect(item_schema["required"]).to match_array(described_class::ITEM_KEYS)
      expect(candidate_schema["required"]).to match_array(described_class::CANDIDATE_KEYS)
      expect(association_schema["required"]).to match_array(described_class::ASSOCIATION_KEYS)
      expect(item_schema.dig("properties", "evidence_class", "enum")).to match_array(
        described_class::EVIDENCE_CLASSES
      )
      expect(item_schema.dig("properties", "adoption_outcome", "enum")).to match_array(
        described_class::ADOPTION_OUTCOMES
      )
      expect(
        item_schema.dig("properties", "adoption_blocking_reasons", "items", "enum")
      ).to match_array(described_class::BLOCKING_REASONS)
      expect(candidate_schema.dig("properties", "validation_state", "enum")).to match_array(
        described_class::CANDIDATE_STATES
      )
      expect(association_schema.dig("properties", "evidence_scope", "enum")).to match_array(
        described_class::EVIDENCE_SCOPES
      )
    end
  end

  it "keeps adoption evidence outside the canonical and calculation-mode cases" do
    aggregate_failures do
      expect(GeneratedReceipts.legacy_case_paths.size).to eq(112)
      expect(GeneratedReceipts.measurement_case_paths.size).to eq(10)
      expect(GeneratedReceipts.legacy_case_paths.size + GeneratedReceipts.measurement_case_paths.size).to eq(122)
      expect(GeneratedReceipts.calculation_mode_case_paths.size).to eq(23)
      expect(GeneratedReceipts.case_paths.size).to eq(145)
      expect(GeneratedReceipts.adoption_evidence_case_paths).to all(
        start_with("#{GeneratedReceipts::ADOPTION_EVIDENCE_CASES_DIR}/")
      )
    end
  end

  it "locks the complete fourteen-case evidence matrix" do
    expected_case_ids = (123..136).map do |number|
      path = GeneratedReceipts.adoption_evidence_case_paths.find do |candidate|
        File.basename(candidate).start_with?("g#{number}_")
      end
      File.basename(path.to_s, ".json")
    end

    aggregate_failures do
      expect(GeneratedReceipts.adoption_evidence_case_paths.size).to eq(14)
      expect(expected_case_ids).to all(match(/\Ag\d{3}_a1_/))
      GeneratedReceipts.adoption_evidence_case_paths.each do |path|
        expect(described_class.call(described_class.load_file(path))).to be_valid
      end
    end
  end

  it "validates a ground-truth-first candidate-only eligible case" do
    expect(described_class.call(evidence_case)).to be_valid
  end

  it "derives same-item eligibility from the evidence association" do
    data = deep_dup(evidence_case)
    data.dig("ground_truth", "expected_associations", 0)["evidence_scope"] = "outside_item"

    result = described_class.call(data)

    expect(result.errors).to include(
      "ground_truth.items[0].adoption_blocking_reasons: must equal derived blockers " \
        "[\"same_item_evidence_incomplete\"]"
    )
  end

  it "reuses the existing renderers without requiring accounting expectations" do
    text = GeneratedReceipts::TextRenderer.call(evidence_case)

    aggregate_failures do
      expect(text).to eq("SYNTHETIC RECEIPT\n税込 120円/100g\n250g\n")
      expect(GeneratedReceipts::HtmlRenderer.call(evidence_case)).to include("SYNTHETIC RECEIPT")
    end
  end

  it "recomputes every adoption blocker instead of trusting the fixture label" do
    mutations = {
      "printed total" => [
        ->(item, _candidate) { item["printed_line_total"] = 300 },
        [ "printed_total_present" ]
      ],
      "existing authority" => [
        ->(item, _candidate) { item["existing_authority"] = true },
        [ "existing_authority_present" ]
      ],
      "same-item evidence" => [
        ->(item, _candidate) { item["same_item_evidence"] = false },
        [ "same_item_evidence_incomplete" ]
      ],
      "package conflict" => [
        ->(item, _candidate) { item["package_conflict"] = true },
        [ "package_conflict" ]
      ],
      "discount conflict" => [
        ->(item, _candidate) { item["discount_conflict"] = true },
        [ "discount_conflict" ]
      ],
      "candidate state" => [
        lambda do |_item, candidate|
          candidate["validation_state"] = "ambiguous"
          candidate["rejection_reasons"] = [ "ambiguous_reference_expression" ]
        end,
        [ "candidate_not_valid" ]
      ],
      "reference components" => [
        ->(_item, candidate) { candidate["reference_quantity"] = nil },
        [ "reference_components_incomplete", "deterministic_projection_unavailable" ]
      ],
      "purchased components" => [
        ->(_item, candidate) { candidate["purchased_quantity"] = nil },
        [ "purchased_components_incomplete", "deterministic_projection_unavailable" ]
      ],
      "tax basis" => [
        ->(_item, candidate) { candidate["reference_price_tax_inclusion"] = "unknown" },
        [ "item_local_tax_basis_missing", "deterministic_projection_unavailable" ]
      ]
    }

    aggregate_failures do
      mutations.each do |label, (mutate, expected_reasons)|
        data = deep_dup(evidence_case)
        item = data.dig("ground_truth", "items", 0)
        candidate = data.dig("ground_truth", "expected_candidates", 0)
        mutate.call(item, candidate)

        result = described_class.call(data)

        expect(result.errors).to include(
          "ground_truth.items[0].adoption_blocking_reasons: must equal derived blockers #{expected_reasons.inspect}"
        ), label
      end
    end
  end

  it "requires an item-local exact tax rate for a net candidate" do
    data = deep_dup(evidence_case)
    candidate = data.dig("ground_truth", "expected_candidates", 0)
    candidate["reference_price_tax_inclusion"] = "net"
    item = data.dig("ground_truth", "items", 0)
    item["deterministic_projection"] = false
    item["projected_gross_line_total"] = nil

    result = described_class.call(data)

    expect(result.errors).to include(
      "ground_truth.items[0].adoption_blocking_reasons: must equal derived blockers " \
        "[\"item_local_tax_rate_missing_or_conflicting\", \"deterministic_projection_unavailable\"]"
    )
  end

  it "accepts a net candidate only with a non-conflicting item-local tax rate" do
    data = deep_dup(evidence_case)
    item = data.dig("ground_truth", "items", 0)
    item["item_local_tax_rate"] = "0.1"
    item["projected_gross_line_total"] = 330
    data.dig("ground_truth", "expected_candidates", 0)["reference_price_tax_inclusion"] = "net"

    expect(described_class.call(data)).to be_valid
  end


  it "derives projection bounds independently from the candidate components" do
    data = deep_dup(evidence_case)
    item = data.dig("ground_truth", "items", 0)
    candidate = data.dig("ground_truth", "expected_candidates", 0)
    candidate.merge!(
      "reference_price_amount" => "999999999999",
      "reference_quantity" => "1",
      "purchased_quantity" => "2",
      "projected_line_total" => nil
    )
    item.merge!(
      "projection_within_bounds" => false,
      "projected_gross_line_total" => nil,
      "adoption_outcome" => "unsupported",
      "adoption_blocking_reasons" => [ "projected_amount_out_of_bounds" ]
    )

    expect(described_class.call(data)).to be_valid
  end

  it "requires exactly one candidate before candidate components can be eligible" do
    data = deep_dup(evidence_case)
    data["ground_truth"]["expected_candidates"] = []
    data["ground_truth"]["expected_associations"] = []
    data.dig("ground_truth", "items", 0).merge!(
      "deterministic_projection" => false,
      "projected_gross_line_total" => nil,
      "adoption_outcome" => "review",
      "adoption_blocking_reasons" => [ "candidate_count_not_one" ]
    )

    result = described_class.call(data)

    expect(result).to be_valid
  end

  it "does not trust self-declared projection facts" do
    data = deep_dup(evidence_case)
    data.dig("ground_truth", "items", 0)["deterministic_projection"] = false

    result = described_class.call(data)

    expect(result.errors).to include(
      "ground_truth.items[0].deterministic_projection: must equal independently derived true"
    )
  end

  it "distinguishes a known cross-dimension conflict from missing projection evidence" do
    data = deep_dup(evidence_case)
    item = data.dig("ground_truth", "items", 0)
    candidate = data.dig("ground_truth", "expected_candidates", 0)
    candidate.merge!(
      "purchased_unit_code" => "liter",
      "projected_line_total" => nil,
      "validation_state" => "unsupported",
      "rejection_reasons" => [ "incompatible_unit_dimension" ]
    )
    item.merge!(
      "dimension_compatible" => false,
      "deterministic_projection" => false,
      "projected_gross_line_total" => nil,
      "adoption_outcome" => "unsupported",
      "adoption_blocking_reasons" => [
        "candidate_not_valid",
        "dimension_incompatible",
        "deterministic_projection_unavailable"
      ]
    )

    expect(described_class.call(data)).to be_valid
  end

  it "does not misclassify an incomplete candidate as dimension or bounds failure" do
    data = deep_dup(evidence_case)
    item = data.dig("ground_truth", "items", 0)
    candidate = data.dig("ground_truth", "expected_candidates", 0)
    candidate.merge!(
      "reference_quantity" => nil,
      "projected_line_total" => nil,
      "validation_state" => "missing",
      "rejection_reasons" => [ "missing_reference_quantity" ]
    )
    item.merge!(
      "deterministic_projection" => false,
      "projected_gross_line_total" => nil,
      "adoption_outcome" => "review",
      "adoption_blocking_reasons" => [
        "candidate_not_valid",
        "reference_components_incomplete",
        "deterministic_projection_unavailable"
      ]
    )

    aggregate_failures do
      expect(described_class.call(data)).to be_valid
      expect(item["dimension_compatible"]).to be(true)
      expect(item["projection_within_bounds"]).to be(true)
    end
  end

  it "derives unsupported only for non-reference, unsupported, or incompatible evidence" do
    data = deep_dup(evidence_case)
    item = data.dig("ground_truth", "items", 0)
    item.merge!(
      "evidence_class" => "package_content",
      "package_conflict" => true,
      "adoption_outcome" => "review",
      "adoption_blocking_reasons" => [ "package_conflict" ]
    )

    result = described_class.call(data)

    expect(result.errors).to include(
      "ground_truth.items[0].adoption_outcome: must equal derived outcome unsupported"
    )
  end

  it "requires candidate associations to cover each candidate exactly once" do
    data = deep_dup(evidence_case)
    data["ground_truth"]["expected_associations"] = []

    result = described_class.call(data)

    expect(result.errors).to include(
      "ground_truth.expected_associations: candidate indexes must exactly cover expected_candidates"
    )
  end

  it "rejects unapproved persistence and authority fields" do
    data = deep_dup(evidence_case)
    data["ground_truth"]["items"][0]["pricing_source_kind"] = "reference_quantity_price"

    result = described_class.call(data)

    aggregate_failures do
      expect(result).not_to be_valid
      expect(result.errors).to include("ground_truth.items[0].invalid_key: is not allowed")
      expect(result.errors.join).not_to include("pricing_source_kind")
    end
  end

  it "loads only bounded regular JSON files from the evidence directory" do
    Dir.mktmpdir do |dir|
      stub_const("GeneratedReceipts::ADOPTION_EVIDENCE_CASES_DIR", dir)
      path = File.join(dir, "g123_adoption_gross_no_total.json")
      File.write(path, JSON.generate(evidence_case))

      expect(described_class.load_file(path)).to eq(evidence_case)
      expect do
        described_class.load_file(File.join(__dir__, "../../../fixtures/generated_receipts/case_schema.json"))
      end.to raise_error(
        GeneratedReceipts::AdoptionEvidence::Validator::FixtureLoadError,
        GeneratedReceipts::AdoptionEvidence::Validator::FIXTURE_LOAD_ERROR_MESSAGE
      )
    end
  end
end
