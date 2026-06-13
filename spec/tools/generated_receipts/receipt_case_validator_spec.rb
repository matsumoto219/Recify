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

  it "validates generated receipt cases through g030" do
    results = case_paths.map { |path| [ File.basename(path), described_class.call(described_class.load_file(path)) ] }

    aggregate_failures do
      expect(results.size).to eq(30)
      results.each do |filename, result|
        expect(result.errors).to eq([]), "#{filename}: #{result.errors.join(', ')}"
      end
    end
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
