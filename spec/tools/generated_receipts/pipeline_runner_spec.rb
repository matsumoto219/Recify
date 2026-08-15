# frozen_string_literal: true

require "rails_helper"
require_relative "../../../tools/generated_receipts"

RSpec.describe GeneratedReceipts::PipelineRunner do
  let(:user) do
    create(:user).tap { |user| user.confirm if user.respond_to?(:confirm) }
  end
  let(:case_data) do
    GeneratedReceipts::Validator.load_file(
      File.join(GeneratedReceipts::CASES_DIR, "g001_normal_included_10_cash.json")
    )
  end
  let(:image_path) do
    File.join(GeneratedReceipts::IMAGES_DIR, "g001_normal_included_10_cash.png")
  end

  it "does not call AI when OCR already produced a finalize decision" do
    ocr_result = {
      success: true,
      raw_text: "合計 ¥880",
      "candidates" => {
        "reference_pricing_candidates" => [
          {
            candidate_id: "azure_items_0_reference_pricing",
            item_index: 0,
            validation_state: "valid",
            rejection_reasons: [],
            reference_price: {
              amount: "1480",
              evidence: { source_field_path: "private/provider/path" }
            },
            reference_quantity: {
              amount: "100",
              unit_code: "gram",
              unit_status: "known",
              unit_raw: "g",
              origin: "explicit",
              evidence: { provider_span_start: 10, provider_span_end: 14 }
            },
            purchased_quantity: {
              amount: "342",
              unit_code: "gram",
              unit_status: "known",
              unit_raw: "g"
            },
            reference_price_tax_inclusion: "gross",
            printed_line_total: { amount: "5061", evidence: { provider_span_start: 20 } },
            corroboration: {
              exact_amount: { numerator: "25308", denominator: "5" },
              projected_amount: 5_062,
              printed_line_total: "5061",
              rounding_matches: [ "floor" ]
            }
          }
        ]
      }
    }

    allow(Receipts::Processing).to receive(:run_ocr).and_return(
      Receipts::Processing::Result.new(
        ocr_result: ocr_result,
        finalize_decision: double("FinalizeDecision"),
        next_step: :finalize
      )
    )
    allow(Receipts::Processing).to receive(:run_finalize)
    expect(Receipts::Processing).not_to receive(:run_ai)

    result = described_class.call(case_data, image_path: image_path, user: user)

    aggregate_failures do
      expect(Receipts::Processing).to have_received(:run_finalize)
      expect(result.dig(:actual, "reference_pricing_candidates")).to eq(
        [
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
      )
      expect(JSON.generate(result.dig(:actual, "reference_pricing_candidates"))).not_to include(
        "evidence",
        "unit_raw",
        "private/provider/path",
        "provider_span"
      )
    end
  end

  it "does not retry generated probe failures caused by external service environment errors" do
    allow(Receipts::Processing).to receive(:run_ocr) do |run|
      run.receipt.update!(
        status: "failed",
        processing_error_code: "external_service_quota_exceeded"
      )
      Receipts::Processing::Result.new(
        ocr_result: { success: false, error_code: "external_service_quota_exceeded" },
        finalize_decision: nil,
        next_step: nil
      )
    end

    described_class.call(case_data, image_path: image_path, user: user)

    expect(Receipts::Processing).to have_received(:run_ocr).once
  end
end
