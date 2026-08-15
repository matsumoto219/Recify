# frozen_string_literal: true

require "json"
require_relative "../../../tools/generated_receipts"

RSpec.describe GeneratedReceipts::Validator do
  def load_case(name)
    described_class.load_file(File.join(GeneratedReceipts::CASES_DIR, "#{name}.json"))
  end

  def deep_dup(value)
    JSON.parse(JSON.generate(value))
  end

  let(:case_paths) { Dir[File.join(GeneratedReceipts::CASES_DIR, "*.json")].sort }
  let(:measurement_case_paths) { GeneratedReceipts.measurement_case_paths }
  let(:case_schema) do
    JSON.parse(File.read(File.expand_path("../../fixtures/generated_receipts/case_schema.json", __dir__)))
  end

  def measurement_case
    deep_dup(load_case("g001_normal_included_10_cash")).tap do |data|
      data["category"] = "measurement"
      data["source"] = {
        "context" => "analysis",
        "items" => [
          {
            "item_index" => 0,
            "printed_lines" => [ "税込 ¥120 / 500ml 1.5L ¥360" ],
            "purchased_quantity" => "1.5",
            "purchased_unit" => "liter",
            "reference_price_amount" => "120",
            "reference_quantity" => "500",
            "reference_unit" => "milliliter",
            "reference_price_tax_inclusion" => "gross",
            "printed_line_total" => 360
          }
        ]
      }
      data["expected"]["items"] = [
        {
          "name" => "サンプル商品A",
          "unit_price" => 120,
          "quantity" => "1.5",
          "quantity_unit_code" => "liter",
          "pricing_source_kind" => nil,
          "reference_price_amount" => nil,
          "reference_quantity" => nil,
          "reference_quantity_unit_code" => nil,
          "reference_price_tax_inclusion" => nil,
          "original_line_total" => 360,
          "line_total" => 360,
          "tax_rate" => 0.1,
          "discount_amount" => 0
        }
      ]
      data["expected"]["measurement_projections"] = [
        {
          "item_index" => 0,
          "exact_reference_amount" => { "numerator" => "360", "denominator" => "1" },
          "projected_reference_line_total" => 360,
          "discount_amount" => 0,
          "discounted_source_line_total" => 360,
          "projected_gross_line_total" => 360
        }
      ]
      data["expected"]["reference_pricing_candidates"] = [
        {
          "item_index" => 0,
          "validation_state" => "valid",
          "rejection_reasons" => [],
          "reference_price_amount" => "120",
          "reference_quantity" => "500",
          "reference_unit_code" => "milliliter",
          "purchased_quantity" => "1.5",
          "purchased_unit_code" => "liter",
          "reference_price_tax_inclusion" => "gross",
          "projected_line_total" => 360,
          "printed_line_total" => "360",
          "rounding_matches" => [ "floor", "half_up", "ceil" ]
        }
      ]
      data["expected"]["subtotal"] = 328
      data["expected"]["tax"] = 32
      data["expected"]["total"] = 360
      data["expected"]["tax_details"] = [
        { "rate" => 0.1, "net" => 328, "tax" => 32, "gross" => 360, "basis" => "gross", "label" => "10%対象計" }
      ]
      data["expected"]["payments"] = [ { "method" => "cash", "label" => "現金", "amount" => 360 } ]
      data["expected"]["payment_sum"] = 360
    end
  end

  it "keeps the JSON schema amount basis enum in sync with the validator" do
    amount_bases = case_schema.dig("properties", "expected", "properties", "amount_basis", "enum")

    expect(amount_bases).to match_array(described_class::AMOUNT_BASES)
  end

  it "keeps source and candidate enums in sync with the validator" do
    source_contexts = case_schema.dig("properties", "source", "properties", "context", "enum")
    candidate_states = case_schema.dig(
      "properties", "expected", "properties", "reference_pricing_candidates", "items", "properties", "validation_state", "enum"
    )
    rejection_reasons = case_schema.dig(
      "properties", "expected", "properties", "reference_pricing_candidates", "items", "properties",
      "rejection_reasons", "items", "enum"
    )

    aggregate_failures do
      expect(source_contexts).to match_array(described_class::SOURCE_CONTEXTS)
      expect(source_contexts).not_to include("legacy")
      expect(candidate_states).to match_array(described_class::REFERENCE_CANDIDATE_STATES)
      expect(rejection_reasons).to match_array(described_class::REFERENCE_CANDIDATE_REJECTION_REASONS)
      expect(described_class::REFERENCE_CANDIDATE_STATES).to include("missing", "none")
    end
  end

  it "validates an additive Measurement source, independent projection, candidate, and persisted authority" do
    result = described_class.call(measurement_case)

    expect(result.errors).to eq([])
  end

  it "rejects drift in the independently asserted exact projection" do
    data = measurement_case
    data["expected"]["measurement_projections"][0]["projected_reference_line_total"] = 359

    result = described_class.call(data)

    expect(result.errors).to include(
      "expected.measurement_projections[0].projected_reference_line_total: must equal independently computed 360"
    )
  end

  it "keeps analysis candidates separate from persisted pricing authority" do
    data = measurement_case
    data["expected"]["items"][0]["pricing_source_kind"] = "reference_quantity_price"
    data["expected"]["items"][0]["reference_price_amount"] = "120"

    result = described_class.call(data)

    expect(result.errors).to include(
      "expected.items[0].pricing_source_kind: must remain null for analysis candidate-only cases"
    )
  end

  it "ties candidate source values to the independently declared Measurement source" do
    data = measurement_case
    data["expected"]["reference_pricing_candidates"][0]["reference_price_amount"] = "999"

    result = described_class.call(data)

    expect(result.errors).to include(
      "expected.reference_pricing_candidates[0].reference_price_amount: must match source.items[0].reference_price_amount"
    )
  end

  it "independently validates candidate rounding corroboration and state reasons" do
    data = measurement_case
    data["expected"]["reference_pricing_candidates"][0]["rounding_matches"] = [ "floor" ]
    data["expected"]["reference_pricing_candidates"][0]["rejection_reasons"] = [ "missing_reference_price" ]

    result = described_class.call(data)

    aggregate_failures do
      expect(result.errors).to include(
        "expected.reference_pricing_candidates[0].rounding_matches: must match independently computed item-end rounding corroboration"
      )
      expect(result.errors).to include(
        "expected.reference_pricing_candidates[0].rejection_reasons: must be empty for valid"
      )
    end
  end

  it "rejects projection and candidate entries that do not belong to a source item" do
    data = measurement_case
    data["expected"]["measurement_projections"] << data["expected"]["measurement_projections"].first.merge(
      "item_index" => 9
    )
    data["expected"]["reference_pricing_candidates"] << {
      "item_index" => 9,
      "validation_state" => "none",
      "rejection_reasons" => []
    }

    result = described_class.call(data)

    aggregate_failures do
      expect(result.errors).to include(
        "expected.measurement_projections: item indexes must exactly match source.items"
      )
      expect(result.errors).to include(
        "expected.reference_pricing_candidates: item indexes must exactly match source.items"
      )
    end
  end

  it "requires every expected item to have an explicit Measurement source line" do
    data = measurement_case
    data["expected"]["items"] << {
      "name" => "画像にない明細",
      "unit_price" => 0,
      "quantity" => 1,
      "line_total" => 0,
      "tax_rate" => 0,
      "discount_amount" => 0
    }

    result = described_class.call(data)

    expect(result.errors).to include(
      "source.items: item indexes must exactly cover expected.items"
    )
  end

  it "requires at least one non-empty rendered source line for every Measurement item" do
    data = measurement_case
    data["source"]["items"][0]["printed_lines"] = []

    result = described_class.call(data)

    expect(result.errors).to include(
      "source.items[0].printed_lines: must contain at least one non-empty string"
    )
  end

  it "does not allow a projectable source to hide behind a none candidate expectation" do
    data = measurement_case
    candidate = data["expected"]["reference_pricing_candidates"][0]
    candidate["validation_state"] = "none"

    result = described_class.call(data)

    aggregate_failures do
      expect(result.errors).to include(
        "expected.reference_pricing_candidates[0].validation_state: cannot be none for an independently projectable source"
      )
      expect(result.errors).to include(
        "expected.reference_pricing_candidates[0]: must not include source fields when validation_state is none"
      )
    end
  end

  it "does not turn an analysis candidate without a printed item total into persisted authority" do
    data = measurement_case
    data["source"]["items"][0].delete("printed_line_total")
    data["source"]["items"][0]["printed_lines"] = [ "税込 ¥120 / 500ml 1.5L" ]
    data["expected"]["items"][0]["original_line_total"] = nil
    data["expected"]["items"][0]["line_total"] = 361

    result = described_class.call(data)

    expect(result.errors).to include(
      "expected.items[0].line_total: must remain null when analysis has no printed item total"
    )
  end

  it "preserves both analysis item totals from the printed item total" do
    data = measurement_case
    data["expected"]["items"][0]["original_line_total"] = 359

    result = described_class.call(data)

    expect(result.errors).to include(
      "expected.items[0].original_line_total: must preserve printed_line_total 360"
    )
  end

  it "binds analysis purchased quantity and unit to the declared OCR source" do
    data = measurement_case
    data["expected"]["items"][0]["quantity"] = "2"
    data["expected"]["items"][0]["quantity_unit_code"] = "gram"

    result = described_class.call(data)

    aggregate_failures do
      expect(result.errors).to include(
        "expected.items[0].quantity: must match source.items[0].purchased_quantity"
      )
      expect(result.errors).to include(
        "expected.items[0].quantity_unit_code: must match source.items[0].purchased_unit"
      )
    end
  end

  it "binds persisted item discount to the independent Measurement projection" do
    data = measurement_case
    data["expected"]["items"][0]["discount_amount"] = 99

    result = described_class.call(data)

    expect(result.errors).to include(
      "expected.items[0].discount_amount: must equal the independently projected discount 0"
    )
  end

  it "rejects conflicting rate and amount discount evidence in the same source" do
    data = measurement_case
    data["source"]["items"][0]["discount_rate"] = "0.1"
    data["source"]["items"][0]["discount_amount"] = 99

    result = described_class.call(data)

    expect(result.errors).to include(
      "source.items[0].discount_amount: must equal the independently projected discount 36"
    )
  end

  it "ties manual reference authority to the independent source projection" do
    data = measurement_case
    data["source"]["context"] = "manual"
    data["source"]["items"][0].delete("printed_line_total")
    data["source"]["items"][0]["printed_lines"] = [ "税込 ¥120 / 500ml 1.5L" ]
    data["expected"]["items"][0].merge!(
      "pricing_source_kind" => "reference_quantity_price",
      "reference_price_amount" => "120",
      "reference_quantity" => "500",
      "reference_quantity_unit_code" => "milliliter",
      "reference_price_tax_inclusion" => "gross",
      "original_line_total" => 360,
      "line_total" => 361
    )

    result = described_class.call(data)

    expect(result.errors).to include(
      "expected.items[0].line_total: must equal the independently projected persisted source amount 360"
    )
  end

  it "keeps manual explicit authority on the printed item total instead of its diagnostic projection" do
    data = measurement_case
    data["source"]["context"] = "manual"
    data["expected"]["items"][0].merge!(
      "pricing_source_kind" => "explicit_line_total",
      "original_line_total" => 359,
      "line_total" => 360
    )

    result = described_class.call(data)

    expect(result.errors).to include(
      "expected.items[0].original_line_total: must preserve explicit printed_line_total 360"
    )
  end

  it "keeps purchased quantity and unit bound to source even when line total authority is explicit" do
    data = measurement_case
    data["source"]["context"] = "manual"
    data["expected"]["items"][0].merge!(
      "pricing_source_kind" => "explicit_line_total",
      "quantity" => "2",
      "quantity_unit_code" => "gram"
    )

    result = described_class.call(data)

    aggregate_failures do
      expect(result.errors).to include(
        "expected.items[0].quantity: must match source.items[0].purchased_quantity"
      )
      expect(result.errors).to include(
        "expected.items[0].quantity_unit_code: must match source.items[0].purchased_unit"
      )
    end
  end

  it "rejects count or missing authority when a manual or edit-save Measurement source is declared" do
    aggregate_failures do
      %w[manual edit_save].product([ "count_unit_price", nil ]).each do |context, source_kind|
        data = measurement_case
        data["source"]["context"] = context
        data["expected"]["items"][0]["pricing_source_kind"] = source_kind

        result = described_class.call(data)

        expect(result.errors).to include(
          "expected.items[0].pricing_source_kind: must declare reference or explicit authority for a Measurement source"
        ), "context=#{context} source_kind=#{source_kind.inspect}"
      end
    end
  end

  it "requires an exact projectable gross or net basis for manual and edit-save reference authority" do
    aggregate_failures do
      %w[manual edit_save].each do |context|
        data = measurement_case
        data["source"]["context"] = context
        data["source"]["items"][0]["reference_price_tax_inclusion"] = nil
        data["expected"]["items"][0].merge!(
          "pricing_source_kind" => "reference_quantity_price",
          "reference_price_amount" => "120",
          "reference_quantity" => "500",
          "reference_quantity_unit_code" => "milliliter",
          "reference_price_tax_inclusion" => nil,
          "original_line_total" => 360,
          "line_total" => 360
        )
        candidate = data["expected"]["reference_pricing_candidates"][0]
        candidate["validation_state"] = "ambiguous"
        candidate["rejection_reasons"] = [ "ambiguous_tax_inclusion" ]
        candidate["reference_price_tax_inclusion"] = nil
        data["expected"]["measurement_projections"][0]["projected_gross_line_total"] = nil

        result = described_class.call(data)

        expected_basis = context == "manual" ? "gross" : "gross or net"
        expect(result.errors).to include(
          "source.items[0].reference_price_tax_inclusion: must be #{expected_basis} for #{context} reference authority"
        ), context
      end
    end
  end

  it "keeps receipt and non-receipt required keys in sync with the validator" do
    expected_condition = case_schema.dig("allOf", 0)
    receipt_required = expected_condition&.dig("then", "properties", "expected", "required")
    non_receipt_required = expected_condition&.dig("else", "properties", "expected", "required")

    aggregate_failures do
      expect(receipt_required).to match_array(described_class::EXPECTED_REQUIRED_KEYS)
      expect(non_receipt_required).to match_array(described_class::NON_RECEIPT_EXPECTED_REQUIRED_KEYS)
      expect(case_schema.dig("properties", "expected", "required")).to be_nil
    end
  end

  it "validates generated receipt cases through g112" do
    results = case_paths.map { |path| [ File.basename(path), described_class.call(described_class.load_file(path)) ] }

    aggregate_failures do
      expect(results.size).to eq(112)
      results.each do |filename, result|
        expect(result.errors).to eq([]), "#{filename}: #{result.errors.join(', ')}"
      end
    end
  end

  it "validates the additive Measurement cases separately from the existing 112 cases" do
    results = measurement_case_paths.map do |path|
      [ File.basename(path), described_class.call(described_class.load_file(path)) ]
    end

    aggregate_failures do
      expect(case_paths.size).to eq(112)
      expect(results.size).to eq(10)
      expect(GeneratedReceipts.case_paths.size).to eq(122)
      results.each do |filename, result|
        expect(result.errors).to eq([]), "#{filename}: #{result.errors.join(', ')}"
      end
    end
  end

  it "covers the generated discount/adjustment and tax/rounding expansion cases" do
    cases = case_paths.map { |path| described_class.load_file(path) }

    aggregate_failures do
      expect(cases.count { |case_data| case_data["case_id"].match?(/\Ag0(?:3[1-9]|4[0-5])_d/) }).to eq(15)
      expect(cases.count { |case_data| case_data["case_id"].match?(/\Ag0(?:4[6-9]|5[0-9]|60)_t/) }).to eq(15)
      expect(cases.count { |case_data| case_data["category"] == "discount_adjustment" }).to be >= 15
      expect(cases.count { |case_data| case_data["category"] == "tax_rounding" }).to be >= 15
      expect(cases.count { |case_data| case_data["case_id"].match?(/\Ag0(?:6[1-9]|7[0-9]|80)_/) }).to eq(20)
      expect(cases.count { |case_data| case_data["case_id"].match?(/\Ag08[1-9]_|\Ag090_/) }).to eq(10)
      expect(cases.count { |case_data| case_data["case_id"].match?(/\Ag09[1-9]_|\Ag100_/) }).to eq(10)
      expect(cases.count { |case_data| case_data["case_id"].match?(/\Ag10[1-9]_|\Ag11[0-2]_/) }).to eq(12)
      expect(cases.count { |case_data| case_data["category"] == "ocr_anomaly" }).to be >= 20
      expect(cases.count { |case_data| case_data["category"] == "non_receipt" }).to eq(10)
      expect(cases.count { |case_data| case_data["category"] == "conflict" }).to eq(10)
      expect(cases.count { |case_data| case_data.dig("expected", "amount_basis") == "mixed" }).to be >= 8
    end
  end

  it "keeps the g112 quantity-bearing bag line item-owned" do
    data = load_case("g112_item_owned_bag_quantity")

    aggregate_failures do
      expect(data.dig("expected", "items")).to include(
        include("name" => "レジ袋中1枚", "line_total" => 3, "tax_rate" => 0.1)
      )
      expect(data.dig("expected", "receipt_adjustments")).to eq([])
      expect(data.dig("expected", "review_reasons")).to eq([])
    end
  end

  it "allows non-receipt cases to define only failure expectations" do
    data = load_case("g081_non_receipt_memo")

    result = described_class.call(data)

    expect(result.errors).to eq([])
  end

  it "rejects unexpected keys" do
    data = deep_dup(load_case("g001_normal_included_10_cash"))
    data["expected"]["unexpected_amount"] = 123

    result = described_class.call(data)

    expect(result.errors).to include("expected.invalid_key: is not allowed")
  end

  it "rejects item line total drift" do
    data = deep_dup(load_case("g001_normal_included_10_cash"))
    data["expected"]["items"][0]["line_total"] = 551

    result = described_class.call(data)

    expect(result.errors).to include("expected.items[0].line_total: must equal unit_price * quantity - discount_amount (550)")
  end

  it "rejects tax detail calculation drift" do
    data = deep_dup(load_case("g003_tax_multi_rate_gross"))
    data["expected"]["tax_details"][0]["tax"] = 25

    result = described_class.call(data)

    expect(result.errors).to include("expected.tax_details[0].gross: must equal net + tax")
      .or include("expected.tax_details[0].tax: must equal 24 for gross basis")
  end

  it "validates mixed price basis lines within the same tax rate" do
    data = load_case("g101_mixed_price_basis_convenience_standard")

    result = described_class.call(data)

    expect(result.errors).to eq([])
  end

  it "requires explicit tax inclusion for mixed price basis items" do
    data = deep_dup(load_case("g101_mixed_price_basis_convenience_standard"))
    data["expected"]["items"][0].delete("tax_inclusion")

    result = described_class.call(data)

    expect(result.errors).to include("expected.items[0].tax_inclusion: is required when expected.amount_basis is mixed")
  end

  it "validates payment adjustments against payment_sum" do
    data = deep_dup(load_case("g010_ocr_noise_payment_context"))
    data["expected"]["payments"][0]["amount"] = 255
    data["expected"]["payment_sum"] = 255

    result = described_class.call(data)

    expect(result.errors).to include("expected.payment_sum: must equal total plus payment adjustments 250")
  end
end
