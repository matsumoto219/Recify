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

  it "validates generated receipt cases through g100" do
    results = case_paths.map { |path| [ File.basename(path), described_class.call(described_class.load_file(path)) ] }

    aggregate_failures do
      expect(results.size).to eq(100)
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
      expect(cases.count { |case_data| case_data["category"] == "ocr_anomaly" }).to be >= 20
      expect(cases.count { |case_data| case_data["category"] == "non_receipt" }).to eq(10)
      expect(cases.count { |case_data| case_data["category"] == "conflict" }).to eq(10)
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

    expect(result.errors).to include("expected.unexpected_amount: is not allowed")
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

  it "validates payment adjustments against payment_sum" do
    data = deep_dup(load_case("g010_ocr_noise_payment_context"))
    data["expected"]["payments"][0]["amount"] = 255
    data["expected"]["payment_sum"] = 255

    result = described_class.call(data)

    expect(result.errors).to include("expected.payment_sum: must equal total plus payment adjustments 250")
  end
end
