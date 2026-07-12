require 'rails_helper'

RSpec.describe Receipts::Processing::StatusTransition do
  it 'marks a receipt processing while clearing terminal error state' do
    receipt = create(
      :receipt,
      :failed,
      :with_image,
      processing_error_code: 'ocr_api_error',
      processing_error_message: 'safe error',
      review_reasons: [ 'ocr_low_confidence' ]
    )

    described_class.mark_processing!(receipt)

    expect(receipt.reload).to have_attributes(
      status: 'processing',
      processing_error_code: nil,
      processing_error_message: nil,
      review_reasons: []
    )
  end

  it 'raises when the receipt transition cannot be persisted' do
    receipt = instance_double(Receipt)
    allow(receipt).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)

    expect do
      described_class.mark_processing!(receipt)
    end.to raise_error(ActiveRecord::RecordInvalid)
  end
end
