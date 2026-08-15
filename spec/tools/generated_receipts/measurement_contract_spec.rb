# frozen_string_literal: true

require_relative "../../../tools/generated_receipts"

RSpec.describe GeneratedReceipts::MeasurementContract do
  def project(**overrides)
    described_class.project(
      source_item: {
        "purchased_quantity" => "1.5",
        "purchased_unit" => "liter",
        "reference_price_amount" => "120",
        "reference_quantity" => "500",
        "reference_unit" => "milliliter",
        "reference_price_tax_inclusion" => "gross"
      }.merge(overrides),
      tax_rate: "0.1",
      tax_rounding: "floor",
      discount_rounding: "round"
    )
  end

  it "calculates exact reference extensions without using the production Amount helper" do
    result = project

    expect(result).to have_attributes(
      exact_reference_amount: Rational(360),
      projected_reference_line_total: 360,
      discount_amount: 0,
      discounted_source_line_total: 360,
      projected_gross_line_total: 360
    )
  end

  it "converts mass and volume units with tooling-local exact scales" do
    vectors = [
      [
        {
          "purchased_quantity" => "342",
          "purchased_unit" => "gram",
          "reference_price_amount" => "1480",
          "reference_quantity" => "0.1",
          "reference_unit" => "kilogram",
          "reference_price_tax_inclusion" => "gross"
        },
        Rational(25_308, 5),
        5_062
      ],
      [
        {
          "purchased_quantity" => "250",
          "purchased_unit" => "milliliter",
          "reference_price_amount" => "980",
          "reference_quantity" => "1000",
          "reference_unit" => "cubic_centimeter",
          "reference_price_tax_inclusion" => "gross"
        },
        Rational(245),
        245
      ]
    ]

    aggregate_failures do
      vectors.each do |source_item, exact_amount, projected_amount|
        result = project(**source_item)

        expect(result.exact_reference_amount).to eq(exact_amount)
        expect(result.projected_reference_line_total).to eq(projected_amount)
      end
    end
  end

  it "rounds the item extension once, applies the item discount, then projects net tax" do
    result = project(
      "reference_price_tax_inclusion" => "net",
      "discount_rate" => "0.1"
    )

    expect(result).to have_attributes(
      exact_reference_amount: Rational(360),
      projected_reference_line_total: 360,
      discount_amount: 36,
      discounted_source_line_total: 324,
      projected_gross_line_total: 356
    )
  end

  it "returns no projection for incomplete, unknown, or cross-dimension evidence" do
    invalid_sources = [
      { "reference_quantity" => nil },
      { "reference_unit" => "lb" },
      { "reference_unit" => "gram" }
    ]

    invalid_sources.each do |source|
      expect(project(**source)).to be_nil, source.inspect
    end
  end

  it "independently identifies which item-end rounding modes match a printed total" do
    aggregate_failures do
      expect(
        described_class.rounding_matches(
          exact_amount: Rational(25_308, 5),
          printed_line_total: 5_062
        )
      ).to eq(%w[half_up ceil])
      expect(
        described_class.rounding_matches(
          exact_amount: Rational(25_308, 5),
          printed_line_total: 5_061
        )
      ).to eq([ "floor" ])
      expect(
        described_class.rounding_matches(
          exact_amount: Rational(360),
          printed_line_total: 356
        )
      ).to eq([])
    end
  end
end
