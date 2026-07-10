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

  it "keeps a safer review_needed result as a warning when completed was expected" do
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

  it "fails when a review_needed case is completed without its review reasons" do
    case_data = load_case("g091_tax_detail_conflict")
    actual = deep_dup(GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data))
    actual["status"] = "completed"
    actual["review_reasons"] = []

    result = described_class.call(case_data, actual)

    aggregate_failures do
      expect(result.status).to eq("FAIL")
      expect(result.diffs).to include(
        hash_including(
          path: "status",
          expected: "review_needed",
          actual: "completed",
          severity: "FAIL"
        )
      )
      expect(result.diffs).to include(hash_including(path: "review_reasons"))
    end
  end

  it "fails when a completed receipt remains failed after processing" do
    case_data = load_case("g001_normal_included_10_cash")
    actual = deep_dup(GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data))
    actual["status"] = "failed"

    result = described_class.call(case_data, actual)

    expect(result).not_to be_pass
    expect(result.diffs).to include(hash_including(path: "status", severity: "FAIL"))
  end

  it "compares non-receipt failures by status and processing error code" do
    case_data = load_case("g081_non_receipt_memo")
    actual = {
      "status" => "completed",
      "review_reasons" => [],
      "processing_error_code" => nil,
      "store_name" => "Generated Receipt Probe",
      "total" => 1
    }

    result = described_class.call(case_data, actual)

    aggregate_failures do
      expect(result.status).to eq("FAIL")
      expect(result.diffs).to include(hash_including(path: "status", severity: "FAIL"))
      expect(result.diffs).to include(hash_including(path: "processing_error_code", severity: "FAIL"))
      expect(result.diffs.map { |diff| diff[:path] }).not_to include("store_name", "total")
    end
  end

  it "compares payment labels and amounts" do
    case_data = load_case("g006_payment_point_credit")
    actual = deep_dup(GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data))
    actual["payments"][0]["amount"] = 299

    result = described_class.call(case_data, actual)

    expect(result.diffs).to include(hash_including(path: "payments"))
  end

  it "compares adjustment effect, tax rate, and review reasons" do
    case_data = load_case("g007_adjustment_delivery_bag_fee")

    aggregate_failures do
      {
        "effect" => "payment",
        "tax_rate" => 0.08,
        "review_reasons" => [ "adjustment_uncertain" ]
      }.each do |key, value|
        actual = deep_dup(GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data))
        actual["receipt_adjustments"][0][key] = value

        result = described_class.call(case_data, actual)

        expect(result.status).to eq("FAIL")
        expect(result.diffs).to include(hash_including(path: "receipt_adjustments"))
      end
    end
  end

  it "treats item unit price, quantity, line total, and tax rate differences as failures" do
    case_data = load_case("g001_normal_included_10_cash")

    aggregate_failures do
      {
        "unit_price" => 551,
        "quantity" => 2,
        "line_total" => 551,
        "tax_rate" => 0.08
      }.each do |key, value|
        actual = deep_dup(GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data))
        actual["items"][0][key] = value

        result = described_class.call(case_data, actual)

        expect(result.status).to eq("FAIL")
        expect(result.diffs).to include(hash_including(path: "item_amounts", severity: "FAIL"))
      end
    end
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

  it "treats runs with the same normalized comparison result as stable" do
    result = GeneratedReceipts::ComparisonRunner::Result.new(
      case_id: "sample",
      run_results: [
        {
          actual: { "tax_rate" => "0.10" },
          comparison: described_class::Result.new(case_id: "sample", status: "PASS", diffs: [])
        },
        {
          actual: { "tax_rate" => "0.1" },
          comparison: described_class::Result.new(case_id: "sample", status: "PASS", diffs: [])
        }
      ]
    )

    expect(result).to be_stable
  end

  it "keeps runs unstable when normalized comparison diffs differ" do
    result = GeneratedReceipts::ComparisonRunner::Result.new(
      case_id: "sample",
      run_results: [
        {
          comparison: described_class::Result.new(
            case_id: "sample",
            status: "WARN",
            diffs: [ { path: "store_name", expected: "A", actual: "B", severity: "WARN" } ]
          )
        },
        {
          comparison: described_class::Result.new(
            case_id: "sample",
            status: "WARN",
            diffs: [ { path: "store_name", expected: "A", actual: "C", severity: "WARN" } ]
          )
        }
      ]
    )

    expect(result).not_to be_stable
  end

  it "summarizes external service failures as ENV_BLOCKED without hiding real failures" do
    aggregate_failures do
      expect(
        GeneratedReceipts::ComparisonRunner::Result.new(
          case_id: "sample",
          run_results: [
            { status: "ENV_BLOCKED", comparison: described_class::Result.new(case_id: "sample", status: "FAIL", diffs: []) }
          ]
        ).status
      ).to eq("ENV_BLOCKED")

      expect(
        GeneratedReceipts::ComparisonRunner::Result.new(
          case_id: "sample",
          run_results: [
            { status: "ENV_BLOCKED", comparison: described_class::Result.new(case_id: "sample", status: "FAIL", diffs: []) },
            { status: "FAIL", comparison: described_class::Result.new(case_id: "sample", status: "FAIL", diffs: []) }
          ]
        ).status
      ).to eq("FAIL")
    end
  end

  it "classifies external processing errors as ENV_BLOCKED runs" do
    case_data = load_case("g001_normal_included_10_cash")
    actual = deep_dup(GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data)).merge(
      "store_name" => "Generated Receipt Probe",
      "subtotal" => nil,
      "tax" => nil,
      "total" => 1,
      "tax_details" => [],
      "items" => [],
      "payments" => [],
      "status" => "failed",
      "processing_error_code" => "external_service_quota_exceeded"
    )
    receipt = instance_double("Receipt", id: 1)
    run = instance_double("ReceiptAnalysisRun", id: 2)

    allow(GeneratedReceipts::PipelineRunner).to receive(:call).and_return(
      receipt: receipt,
      run: run,
      actual: actual
    )

    result = GeneratedReceipts::ComparisonRunner.new(
      case_data,
      image_path: "/tmp/generated.png",
      user: instance_double("User"),
      runs: 1
    ).call

    aggregate_failures do
      expect(result.status).to eq("ENV_BLOCKED")
      expect(result.run_results.first[:status]).to eq("ENV_BLOCKED")
      expect(result.run_results.first[:diffs]).to include(
        hash_including(
          path: "processing_error_code",
          actual: "external_service_quota_exceeded",
          severity: "ENV_BLOCKED"
        )
      )
    end
  end
end
