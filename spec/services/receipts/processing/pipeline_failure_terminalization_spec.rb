require 'rails_helper'

RSpec.describe 'Receipt finalize failure terminalization' do
  self.use_transactional_tests = false

  def ocr_result
    raw = JSON.parse(Rails.root.join('spec/fixtures/ocr/single_tax_receipt.json').read)

    Ocr::ResponseParser.new(response: raw, provider: :fixture).call
  end

  def finalize_decision
    Receipts::Processing::Contracts::FinalizeDecision.new(
      finalize_strategy: 'ocr_only',
      error_code: nil,
      error_message: nil,
      receipt_attributes: {},
      ocr_result: nil,
      ai_result: nil,
      metadata: {}
    )
  end

  before do
    @user = create(:user, email: "finalize-failure-#{SecureRandom.hex(8)}@example.test")
    @receipt = create(:receipt, :processing, :with_image, user: @user)
    @run = create(:receipt_analysis_run, receipt: @receipt)
    Receipts::Processing.record_ocr_snapshot(@run, ocr_result)
    Receipts::Processing.record_finalize_decision(@run, finalize_decision)
  end

  after do
    blob_ids = ActiveStorage::Attachment.where(
      record_type: 'Receipt',
      record_id: @receipt&.id,
      name: 'image'
    ).pluck(:blob_id)
    Receipt.where(id: @receipt&.id).destroy_all
    ActiveStorage::Blob.where(id: blob_ids).find_each(&:purge)
    User.where(id: @user&.id).destroy_all
  end

  it 'Finalize transaction rollback後も元の例外を保持してrunとReceiptをfailedへ終端する' do
    allow(Receipts::Processing).to receive(:record_final_result).and_raise('summary write failed')

    expect do
      Receipts::Processing.run_finalize(@run)
    end.to raise_error(RuntimeError, 'summary write failed')

    aggregate_failures do
      expect(@run.reload).to have_attributes(
        status: 'failed',
        stage: 'finalize',
        error_code: 'unexpected_error',
        error_message: 'summary write failed'
      )
      expect(@run.final_result_summary).to be_blank
      expect(@run.metadata).not_to have_key('build_params_snapshot')
      expect(@receipt.reload).to have_attributes(
        status: 'failed',
        processing_error_code: 'unexpected_error'
      )
      expect(@receipt.receipt_items).to be_empty
    end
  end
end
