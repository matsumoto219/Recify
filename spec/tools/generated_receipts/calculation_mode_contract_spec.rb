# frozen_string_literal: true

require "json"
require_relative "../../../tools/generated_receipts"

RSpec.describe GeneratedReceipts::CalculationModeContract do
  def source_item(**overrides)
    {
      "item_index" => 0,
      "purchased_quantity" => "2",
      "purchased_unit" => "each",
      "purchased_quantity_origin" => "explicit",
      "count_unit_price_amount" => "500",
      "printed_line_total" => 1_000
    }.merge(overrides.transform_keys(&:to_s))
  end

  def expected_item(**overrides)
    {
      "unit_price" => 500,
      "quantity" => "2",
      "quantity_unit_code" => "each",
      "pricing_source_kind" => "count_unit_price",
      "reference_price_amount" => nil,
      "reference_quantity" => nil,
      "reference_quantity_unit_code" => nil,
      "reference_price_tax_inclusion" => nil,
      "original_line_total" => 1_000,
      "line_total" => 1_000,
      "tax_rate" => 0.1,
      "discount_amount" => 0,
      "needs_review" => false,
      "review_reasons" => []
    }.merge(overrides.transform_keys(&:to_s))
  end

  def calculation_case(source: source_item, expected: expected_item)
    {
      "category" => "calculation_mode",
      "source" => {
        "context" => "analysis",
        "count_tax_semantics" => "reproducible_as_recorded",
        "items" => [ source ]
      },
      "expected" => {
        "rounding" => { "tax" => "floor", "discount" => "round" },
        "items" => [ expected ]
      }
    }
  end

  def validate(value)
    described_class.validate(value)
  end

  it "independently validates exact count pricing and applies an item discount once" do
    data = calculation_case(
      source: source_item(discount_amount: 100, printed_line_total: 900),
      expected: expected_item(line_total: 900, discount_amount: 100)
    )

    expect(validate(data)).to eq([])
  end

  it "does not certify an unclassified expectation when an exact count authority is complete" do
    data = calculation_case(
      expected: expected_item(
        unit_price: nil,
        quantity: nil,
        quantity_unit_code: nil,
        pricing_source_kind: nil,
        original_line_total: nil,
        line_total: nil
      )
    )

    expect(validate(data)).to include(
      "expected.items[0].pricing_source_kind: must select count_unit_price from the declared exact evidence"
    )
  end

  it "prefers a complete matching count formula over explicit line-total authority" do
    data = calculation_case(
      expected: expected_item(
        unit_price: nil,
        pricing_source_kind: "explicit_line_total"
      )
    )

    expect(validate(data)).to include(
      "expected.items[0].pricing_source_kind: must select count_unit_price from the declared exact evidence"
    )
  end

  it "does not allow a fallback quantity to establish count authority" do
    data = calculation_case(source: source_item(purchased_quantity_origin: "fallback"))

    expect(validate(data)).to include(
      "source.items[0].purchased_quantity_origin: must be explicit for count-unit pricing authority"
    )
  end

  it "requires review when count tax semantics are unknown but the printed total corroborates the formula" do
    confirmed = calculation_case
    confirmed["source"]["count_tax_semantics"] = "unknown"
    reviewable = calculation_case(
      expected: expected_item(
        needs_review: true,
        review_reasons: [ "item_pricing_mode_uncertain" ]
      )
    )
    reviewable["source"]["count_tax_semantics"] = "unknown"

    aggregate_failures do
      expect(validate(confirmed)).to include(
        "expected.items[0].review_reasons: must include item_pricing_mode_uncertain for the declared evidence"
      )
      expect(validate(reviewable)).to eq([])
    end
  end

  it "keeps count pricing unresolved when tax semantics and printed total are both unavailable" do
    data = calculation_case(
      source: source_item(printed_line_total: nil),
      expected: expected_item(
        unit_price: nil,
        quantity: nil,
        quantity_unit_code: nil,
        pricing_source_kind: nil,
        original_line_total: nil,
        line_total: nil
      )
    )
    data["source"]["count_tax_semantics"] = "unknown"

    expect(validate(data)).to eq([])
  end

  it "reuses the tooling Measurement contract for gross reference pricing" do
    source = source_item(
      purchased_quantity: "342",
      purchased_unit: "gram",
      count_unit_price_amount: nil,
      reference_price_amount: "498",
      reference_quantity: "100",
      reference_unit: "gram",
      reference_price_tax_inclusion: "gross",
      printed_line_total: 1_703
    )
    expected = expected_item(
      unit_price: nil,
      quantity: "342",
      quantity_unit_code: "gram",
      pricing_source_kind: "reference_quantity_price",
      reference_price_amount: "498",
      reference_quantity: "100",
      reference_quantity_unit_code: "gram",
      reference_price_tax_inclusion: "gross",
      original_line_total: 1_703,
      line_total: 1_703
    )

    expect(validate(calculation_case(source:, expected:))).to eq([])
  end

  it "keeps net reference evidence outside the initial automatic calculation-mode contract" do
    source = source_item(
      purchased_quantity: "1",
      purchased_unit: "kilogram",
      count_unit_price_amount: nil,
      reference_price_amount: "980",
      reference_quantity: "1",
      reference_unit: "kilogram",
      reference_price_tax_inclusion: "net",
      printed_line_total: 1_078
    )
    expected = expected_item(
      unit_price: nil,
      quantity: "1",
      quantity_unit_code: "kilogram",
      pricing_source_kind: "reference_quantity_price",
      reference_price_amount: "980",
      reference_quantity: "1",
      reference_quantity_unit_code: "kilogram",
      reference_price_tax_inclusion: "net",
      original_line_total: 980,
      line_total: 980
    )

    expect(validate(calculation_case(source:, expected:))).to include(
      "source.items[0].reference_price_tax_inclusion: must be gross for reference_quantity_price authority"
    )
  end

  it "validates a strong printed total as explicit authority without inventing formula source" do
    source = source_item(
      purchased_quantity: "1",
      purchased_quantity_origin: "fallback",
      count_unit_price_amount: nil,
      printed_line_total: 180
    )
    expected = expected_item(
      unit_price: nil,
      quantity: "1",
      pricing_source_kind: "explicit_line_total",
      original_line_total: 180,
      line_total: 180
    )

    expect(validate(calculation_case(source:, expected:))).to eq([])
  end

  it "uses explicit authority with mode review when a complete formula conflicts with a strong printed total" do
    source = source_item(printed_line_total: 900)
    expected = expected_item(
      unit_price: nil,
      pricing_source_kind: "explicit_line_total",
      original_line_total: 900,
      line_total: 900,
      needs_review: true,
      review_reasons: [ "item_pricing_mode_uncertain" ]
    )

    expect(validate(calculation_case(source:, expected:))).to eq([])
  end

  it "validates unclassified items without derived amount authority" do
    source = source_item(
      purchased_quantity: nil,
      purchased_unit: nil,
      purchased_quantity_origin: "missing",
      count_unit_price_amount: nil,
      printed_line_total: nil
    )
    expected = expected_item(
      unit_price: nil,
      quantity: nil,
      quantity_unit_code: nil,
      pricing_source_kind: nil,
      original_line_total: nil,
      line_total: nil
    )

    expect(validate(calculation_case(source:, expected:))).to eq([])
  end

  it "derives reviewable only from a persisted mode plus the calculation-mode review reason" do
    reviewable = calculation_case(
      expected: expected_item(
        needs_review: true,
        review_reasons: [ "item_pricing_mode_uncertain" ]
      )
    )
    inconsistent = calculation_case(
      expected: expected_item(
        needs_review: false,
        review_reasons: [ "item_pricing_mode_uncertain" ]
      )
    )
    reviewable["source"]["count_tax_semantics"] = "unknown"
    inconsistent["source"]["count_tax_semantics"] = "unknown"

    aggregate_failures do
      expect(validate(reviewable)).to eq([])
      expect(validate(inconsistent)).to include(
        "expected.items[0].needs_review: must be true when review_reasons are present"
      )
    end
  end

  it "allows an unresolved item to target the calculation-mode control for review" do
    data = calculation_case(
      source: source_item(
        purchased_quantity: nil,
        purchased_unit: nil,
        purchased_quantity_origin: "missing",
        count_unit_price_amount: nil,
        printed_line_total: nil
      ),
      expected: expected_item(
        unit_price: nil,
        quantity: nil,
        quantity_unit_code: nil,
        pricing_source_kind: nil,
        original_line_total: nil,
        line_total: nil,
        needs_review: true,
        review_reasons: [ "item_pricing_mode_uncertain" ]
      )
    )

    expect(validate(data)).to eq([])
  end

  it "preserves unrelated allowlisted item review reasons alongside calculation state" do
    data = calculation_case(
      expected: expected_item(
        needs_review: true,
        review_reasons: [ "item_name_uncertain" ]
      )
    )

    expect(validate(data)).to eq([])
  end

  it "limits calculation-mode fixtures to the OCR analysis context" do
    data = calculation_case
    data["source"]["context"] = "manual"

    expect(validate(data)).to include(
      "source.context: must be analysis for calculation-mode fixtures"
    )
  end

  it "associates source and expected items by a unique bounded item index" do
    duplicate_source = source_item
    data = calculation_case
    data["source"]["items"] << duplicate_source

    expect(validate(data)).to include(
      "source.items: item_index values must uniquely and exactly cover expected.items"
    )
  end

  it "rejects malformed or over-bound exact count source before multiplying" do
    malformed = calculation_case(source: source_item(count_unit_price_amount: "01"))
    oversized = calculation_case(source: source_item(purchased_quantity: "10000"))

    aggregate_failures do
      expect(validate(malformed)).to include(
        "source.items[0].count_unit_price_amount: must be a bounded exact integer"
      )
      expect(validate(oversized)).to include(
        "source.items[0].purchased_quantity: must be an explicit positive countable integer within bounds"
      )
    end
  end

  it "keeps source fields separate from derived and competing-mode fields" do
    data = calculation_case(
      expected: expected_item(
        reference_price_amount: "500",
        original_line_total: 999
      )
    )

    errors = validate(data)

    aggregate_failures do
      expect(errors).to include(
        "expected.items[0].reference_price_amount: must be null for count_unit_price authority"
      )
      expect(errors).to include(
        "expected.items[0].original_line_total: must equal the independently projected count amount 1000"
      )
    end
  end
end
