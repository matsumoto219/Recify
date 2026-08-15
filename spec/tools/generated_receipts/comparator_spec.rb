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

  it "compares persisted measurement source fields only when the fixture declares them" do
    case_data = deep_dup(load_case("g001_normal_included_10_cash"))
    expected_item = case_data.fetch("expected").fetch("items").first
    expected_item.merge!(
      "quantity_unit_code" => "kilogram",
      "pricing_source_kind" => "reference_quantity_price",
      "reference_price_amount" => "3280.5",
      "reference_quantity" => "1.000",
      "reference_quantity_unit_code" => "kilogram",
      "reference_price_tax_inclusion" => "gross",
      "original_line_total" => 4_101
    )
    matching_actual = GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data)
    optional_keys = %w[
      quantity_unit_code
      pricing_source_kind
      reference_price_amount
      reference_quantity
      reference_quantity_unit_code
      reference_price_tax_inclusion
      original_line_total
    ]

    aggregate_failures do
      expect(described_class.call(case_data, matching_actual).status).to eq("PASS")

      optional_keys.each do |key|
        actual = deep_dup(matching_actual)
        actual.fetch("items").first[key] = key == "original_line_total" ? 4_102 : "different"

        result = described_class.call(case_data, actual)

        expect(result.status).to eq("FAIL"), key
        expect(result.diffs).to include(hash_including(path: "item_amounts", severity: "FAIL")), key
      end
    end
  end

  it "ignores undeclared measurement source fields for legacy cases" do
    case_data = load_case("g001_normal_included_10_cash")
    actual = deep_dup(GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data))
    actual.fetch("items").first.merge!(
      "quantity_unit_code" => "kilogram",
      "pricing_source_kind" => "reference_quantity_price",
      "reference_price_amount" => "999",
      "reference_quantity" => "100",
      "reference_quantity_unit_code" => "gram",
      "reference_price_tax_inclusion" => "gross",
      "original_line_total" => 999
    )

    expect(described_class.call(case_data, actual).status).to eq("PASS")
  end

  it "snapshots persisted measurement source decimals without losing precision" do
    item = double(
      confirmed_name: "サンプル量売商品",
      suggested_name: nil,
      raw_text: "サンプル量売商品",
      price: nil,
      quantity: BigDecimal("1.250"),
      quantity_unit_code: "kilogram",
      line_total: 4_101,
      original_line_total: 4_100,
      tax_rate: BigDecimal("0.08"),
      discount_amount: nil,
      pricing_source_kind: "reference_quantity_price",
      reference_price_amount: BigDecimal("3280.500000"),
      reference_quantity: BigDecimal("1.000"),
      reference_quantity_unit_code: "kilogram",
      reference_price_tax_inclusion: "gross"
    )
    empty_relation = double(order: [])
    receipt = double(
      store_name: "サンプルストア",
      subtotal_amount: 3_797,
      tax_amount: 304,
      total_amount: 4_101,
      tax_rate: BigDecimal("0.08"),
      receipt_tax_details: empty_relation,
      receipt_items: double(order: [ item ]),
      receipt_adjustments: empty_relation,
      payment_method: "cash",
      receipt_payments: empty_relation,
      status: "completed",
      review_reasons: [],
      processing_error_code: nil
    )

    snapshot = described_class.snapshot_from_receipt(receipt)

    expect(snapshot.fetch("items").sole).to include(
      "quantity_unit_code" => "kilogram",
      "pricing_source_kind" => "reference_quantity_price",
      "reference_price_amount" => "3280.5",
      "reference_quantity" => "1",
      "reference_quantity_unit_code" => "kilogram",
      "reference_price_tax_inclusion" => "gross",
      "original_line_total" => 4_100
    )
  end

  it "compares OCR reference candidates separately from persisted item authority" do
    case_data = deep_dup(load_case("g001_normal_included_10_cash"))
    case_data.fetch("expected")["reference_pricing_candidates"] = [
      {
        "item_index" => 0,
        "validation_state" => "valid",
        "rejection_reasons" => [],
        "reference_price_amount" => "1480",
        "reference_quantity" => "100",
        "reference_unit_code" => "gram",
        "purchased_quantity" => "342",
        "purchased_unit_code" => "gram",
        "reference_price_tax_inclusion" => "gross",
        "projected_line_total" => 5_062,
        "printed_line_total" => 5_061,
        "rounding_matches" => [ "floor" ]
      }
    ]
    actual = GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data)

    aggregate_failures do
      expect(case_data.dig("expected", "items", 0)).not_to have_key("pricing_source_kind")
      expect(described_class.call(case_data, actual).status).to eq("PASS")

      drifted = deep_dup(actual)
      drifted.dig("reference_pricing_candidates", 0)["validation_state"] = "ambiguous"
      result = described_class.call(case_data, drifted)

      expect(result.status).to eq("FAIL")
      expect(result.diffs).to include(hash_including(path: "reference_pricing_candidates", severity: "FAIL"))
    end
  end

  it "treats none as candidate absence and fails unexpected candidates" do
    case_data = deep_dup(load_case("g001_normal_included_10_cash"))
    case_data.fetch("expected")["reference_pricing_candidates"] = [
      { "item_index" => 0, "validation_state" => "none", "rejection_reasons" => [] }
    ]
    no_candidates = GeneratedReceipts::ComparisonRunner.expected_snapshot(case_data)

    unexpected = deep_dup(no_candidates)
    unexpected["reference_pricing_candidates"] = [
      {
        "item_index" => 0,
        "validation_state" => "unsupported",
        "rejection_reasons" => [ "unsupported_reference_unit" ]
      }
    ]

    aggregate_failures do
      expect(no_candidates["reference_pricing_candidates"]).to eq([])
      expect(described_class.call(case_data, no_candidates).status).to eq("PASS")

      result = described_class.call(case_data, unexpected)
      expect(result.status).to eq("FAIL")
      expect(result.diffs).to include(hash_including(path: "reference_pricing_candidates", severity: "FAIL"))
    end
  end

  it "bounds reference candidate summaries without retaining raw evidence" do
    candidates = Array.new(101) do |index|
      {
        item_index: index,
        validation_state: "unsupported",
        rejection_reasons: Array.new(10) { |reason_index| "reason_#{reason_index}" },
        reference_price: {
          amount: "1.800000",
          evidence: { source_field_path: "documents[0].fields.Items[#{index}].Price" }
        },
        reference_quantity: {
          amount: "1",
          unit_code: "gram",
          unit_raw: "g"
        },
        purchased_quantity: {
          amount: "850",
          unit_code: "gram",
          unit_raw: "g"
        }
      }
    end
    candidates.first[:item_index] = 100
    candidates.first[:printed_line_total] = { amount: "1000000000" }
    candidates.first[:corroboration] = { projected_amount: 1_000_000_000 }

    summaries = described_class.reference_pricing_candidates_summary(candidates)
    serialized = JSON.generate(summaries)

    aggregate_failures do
      expect(summaries.size).to eq(100)
      expect(summaries).to all(include("reference_price_amount" => "1.8"))
      expect(summaries).to all(satisfy { |candidate| candidate.fetch("rejection_reasons").size == 8 })
      expect(summaries.first).not_to include("item_index", "printed_line_total", "projected_line_total")
      expect(serialized).not_to include("evidence", "source_field_path", "unit_raw")
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
