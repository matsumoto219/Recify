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
    ocr_result = { success: true, raw_text: "合計 ¥880" }

    allow(Receipts::Processing).to receive(:run_ocr).and_return(
      Receipts::Processing::Result.new(
        ocr_result: ocr_result,
        finalize_decision: double("FinalizeDecision"),
        next_step: :finalize
      )
    )
    allow(Receipts::Processing).to receive(:run_finalize)
    expect(Receipts::Processing).not_to receive(:run_ai)

    described_class.call(case_data, image_path: image_path, user: user)

    expect(Receipts::Processing).to have_received(:run_finalize)
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
