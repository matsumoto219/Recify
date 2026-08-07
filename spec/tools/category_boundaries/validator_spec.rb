# frozen_string_literal: true

require "rails_helper"
require "json"
require_relative "../../../tools/category_boundaries"

RSpec.describe CategoryBoundaries::Validator do
  let(:fixture_path) { Rails.root.join("spec/fixtures/category_boundaries/cases.json") }
  let(:fixture) { described_class.load_file(fixture_path) }
  let(:allowed_codes) { ReceiptItem::CATEGORIES }

  def deep_dup(value)
    JSON.parse(JSON.generate(value))
  end

  def validate(value)
    described_class.call(value, allowed_codes: allowed_codes)
  end

  it "validates the anonymous category boundary fixture" do
    result = validate(fixture)

    expect(result.errors).to eq([])
  end

  it "covers every canonical category and the unclassified state" do
    expected_codes = fixture.fetch("cases").map { |entry| entry["expected_code"] }.uniq

    aggregate_failures do
      expect(expected_codes.compact).to match_array(allowed_codes)
      expect(expected_codes).to include(nil)
    end
  end

  it "records every rejected candidate as no-go without making it an expected code" do
    decisions = fixture.fetch("candidate_decisions").to_h { |entry| [ entry.fetch("code"), entry.fetch("decision") ] }
    expected_codes = fixture.fetch("cases").filter_map { |entry| entry["expected_code"] }

    aggregate_failures do
      expect(decisions).to eq(
        "electronics" => "no_go",
        "clothing" => "no_go",
        "services" => "no_go",
        "office_supplies" => "no_go",
        "education" => "no_go"
      )
      expect(expected_codes & decisions.keys).to be_empty
    end
  end

  it "rejects unsupported expected codes" do
    invalid = deep_dup(fixture)
    invalid.fetch("cases").first["expected_code"] = "electronics"

    expect(validate(invalid).errors).to include(
      "cases[0].expected_code: must be a canonical category code or null"
    )
  end

  it "rejects duplicate case IDs" do
    invalid = deep_dup(fixture)
    invalid.fetch("cases")[1]["case_id"] = invalid.fetch("cases")[0].fetch("case_id")

    expect(validate(invalid).errors).to include("cases[1].case_id: must be unique")
  end

  it "rejects free-text and other unexpected fields" do
    invalid = deep_dup(fixture)
    invalid.fetch("cases").first["description"] = "free text is not part of this contract"
    invalid.fetch("cases").first["raw_receipt"] = "not allowed"

    aggregate_failures do
      expect(validate(invalid).errors).to include(
        "cases[0].raw_receipt: is not allowed",
        "cases[0].description: is not allowed"
      )
    end
  end

  it "requires unclassified cases to remain under review" do
    invalid = deep_dup(fixture)
    entry = invalid.fetch("cases").find { |candidate| candidate["expected_code"].nil? }
    entry["needs_review"] = false

    expect(validate(invalid).errors).to include(
      "cases[#{invalid.fetch('cases').index(entry)}].needs_review: must be true when expected_code is null"
    )
  end

  it "rejects candidate decisions other than no-go" do
    invalid = deep_dup(fixture)
    invalid.fetch("candidate_decisions").first["decision"] = "go"

    expect(validate(invalid).errors).to include(
      "candidate_decisions[0].decision: must be no_go"
    )
  end
end
