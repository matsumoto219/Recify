# frozen_string_literal: true

require "json"
require_relative "../../../tools/generated_receipts"

RSpec.describe GeneratedReceipts::Comparator do
  def load_case(name)
    described_class_data = GeneratedReceipts::Validator.load_file(File.join(GeneratedReceipts::CASES_DIR, "#{name}.json"))
    validation = GeneratedReceipts::Validator.call(described_class_data)
    expect(validation.errors).to eq([])
    described_class_data
  end

  def deep_dup(value)
    JSON.parse(JSON.generate(value))
  end

  it "passes when an actual snapshot matches expected JSON" do
    case_data = load_case("g001_normal_included_10_cash")
    actual = GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data)

    result = described_class.call(case_data, actual)

    aggregate_failures do
      expect(result.status).to eq("PASS")
      expect(result.diffs).to eq([])
    end
  end

  it "reports critical amount diffs" do
    case_data = load_case("g001_normal_included_10_cash")
    actual = deep_dup(GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data))
    actual["total"] = 881

    result = described_class.call(case_data, actual)

    aggregate_failures do
      expect(result.status).to eq("FAIL")
      expect(result.diffs).to include(hash_including(path: "total", expected: 880, actual: 881))
    end
  end

  it "classifies status and review differences as warnings" do
    case_data = load_case("g001_normal_included_10_cash")
    actual = deep_dup(GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data))
    actual["status"] = "review_needed"
    actual["review_reasons"] = [ "item_name_uncertain" ]

    result = described_class.call(case_data, actual)

    aggregate_failures do
      expect(result.status).to eq("WARN")
      expect(result.diffs).to include(hash_including(path: "status", severity: "WARN"))
      expect(result.diffs).to include(hash_including(path: "review_reasons", severity: "WARN"))
    end
  end

  it "compares payment labels and amounts" do
    case_data = load_case("g006_payment_point_credit")
    actual = deep_dup(GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data))
    actual["payments"][0]["amount"] = 299

    result = described_class.call(case_data, actual)

    expect(result.diffs).to include(hash_including(path: "payments"))
  end

  it "summarizes comparison runs with WARN when no run failed" do
    result = GeneratedReceipts::ComparisonRunner::Result.new(
      case_id: "sample",
      run_results: [
        { comparison: described_class::Result.new(case_id: "sample", status: "PASS", diffs: []) },
        { comparison: described_class::Result.new(case_id: "sample", status: "WARN", diffs: [ { path: "status" } ]) }
      ]
    )

    expect(result.status).to eq("WARN")
  end
end
