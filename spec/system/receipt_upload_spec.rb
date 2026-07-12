require "rails_helper"
require_relative "../support/system_test_helpers"

RSpec.describe "レシート画像uploadの実Chrome回帰", type: :system do
  def sign_in_through_browser(user)
    visit new_user_session_path
    fill_in "user_email", with: user.email
    fill_in "user_password", with: "password"
    click_button I18n.t("auth.sessions.submit")
    expect(page).to have_current_path(receipts_path, ignore_query: true)
  end

  def enable_processing_without_provider_calls
    ENV["RECEIPT_OCR_ENABLED"] = "true"
    ENV["RECEIPT_AI_ENABLED"] = "true"
  end

  def queued_job_classes_since(index)
    ActiveJob::Base.queue_adapter.enqueued_jobs.drop(index).map { |job| job[:job] }
  end

  it "単一画像をpreviewしてprocessing cardとOCR jobを作成する" do
    user = create_system_test_user
    queue_adapter = ActiveJob::Base.queue_adapter
    queued_job_count = queue_adapter.enqueued_jobs.size
    enable_processing_without_provider_calls

    sign_in_through_browser(user)
    visit new_upload_receipts_path
    wait_for_stimulus_controller("receipt-upload")

    image_path = Rails.root.join("spec/fixtures/files/receipt_sample.jpg")
    find("input[data-receipt-upload-target='cameraInput']", visible: :all).attach_file(image_path)

    expect(page).to have_css("[data-receipt-upload-target='previewWrapper']:not(.hidden)")
    expect(page).to have_button(I18n.t("receipts.new_upload.buttons.upload"), disabled: false)
    click_button I18n.t("receipts.new_upload.buttons.upload")

    expect(page).to have_current_path(receipts_path, ignore_query: true)
    receipt = user.receipts.order(:id).last
    run = receipt.receipt_analysis_runs.sole
    aggregate_failures do
      expect(receipt).to have_attributes(status: "processing")
      expect(receipt.image).to be_attached
      expect(run).to have_attributes(source: "upload", status: "queued", stage: "queued")
      expect(queued_job_classes_since(queued_job_count)).to include(ReceiptOcrJob)
    end
    expect(page).to have_css("##{receipt.dom_target_id}[data-receipt-card-phase='queued']")
    expect_browser_console_clean
  end

  it "複数画像のpreviewを切り替えてbatch uploadする" do
    user = create_system_test_user
    queue_adapter = ActiveJob::Base.queue_adapter
    queued_job_count = queue_adapter.enqueued_jobs.size
    receipt_count = user.receipts.count
    enable_processing_without_provider_calls

    sign_in_through_browser(user)
    visit new_upload_receipts_path
    wait_for_stimulus_controller("receipt-upload")

    image_paths = %w[single_tax_receipt.png multiple_tax_receipt.png].map do |filename|
      Rails.root.join("spec/fixtures/files", filename)
    end
    find("input[data-receipt-upload-target='libraryInput']", visible: :all).attach_file(image_paths)

    expect(page).to have_css("[data-receipt-upload-target='previewControls']:not(.hidden)")
    expect(find("[data-receipt-upload-target='previewCounter']").text).to eq("1 / 2")
    find("[data-receipt-upload-target='previewNextButton']").click
    expect(find("[data-receipt-upload-target='previewCounter']").text).to eq("2 / 2")
    expect(find("[data-receipt-upload-target='previewCurrentFileName']").text).to eq("multiple_tax_receipt.png")

    click_button I18n.t("receipts.new_upload.buttons.upload")
    expect(page).to have_current_path(receipts_path, ignore_query: true)

    receipts = user.receipts.order(:id).offset(receipt_count).to_a
    runs = receipts.map { |receipt| receipt.receipt_analysis_runs.sole }
    aggregate_failures do
      expect(receipts.size).to eq(2)
      expect(receipts).to all(have_attributes(status: "processing"))
      expect(receipts).to all(satisfy { |receipt| receipt.image.attached? })
      expect(runs).to all(have_attributes(source: "batch_upload", status: "queued", stage: "queued"))
      expect(queued_job_classes_since(queued_job_count).count(ReceiptOcrJob)).to eq(2)
    end
    receipts.each do |receipt|
      expect(page).to have_css("##{receipt.dom_target_id}[data-receipt-card-phase='queued']")
    end
    expect_browser_console_clean
  end
end
