require 'rails_helper'

RSpec.describe Receipts::Editing::UpdateState do
  it 'applies ReviewState before clearing processing error attributes' do
    receipt = build(
      :receipt,
      :failed,
      processing_error_code: 'ocr_api_error',
      processing_error_message: 'safe error'
    )
    attributes = { 'total_amount' => 1000 }
    review_state_arguments = {
      amount_result: { review_reasons: [ 'tax_amount_mismatch' ] },
      consistency_review_reasons: [],
      child_review_remaining: false,
      nested_amount_inputs_submitted: true,
      item_inputs_submitted: false
    }
    state = Receipts::Editing::ReviewState::Result.new(
      review_reasons: [ 'tax_amount_mismatch' ],
      status: 'review_needed'
    )
    allow(Receipts::Editing::ReviewState).to receive(:call).and_return(state)

    result = described_class.call(
      receipt: receipt,
      attributes: attributes,
      review_state_arguments: review_state_arguments
    )

    aggregate_failures do
      expect(result).to equal(attributes)
      expect(result).to include(
        'review_reasons' => [ 'tax_amount_mismatch' ],
        'status' => 'review_needed',
        'processing_error_code' => nil,
        'processing_error_message' => nil
      )
      expect(Receipts::Editing::ReviewState).to have_received(:call).with(
        receipt: receipt,
        permitted: attributes,
        **review_state_arguments
      )
    end
  end

  it 'clears a failed processing error to completed when no review status is rebuilt' do
    receipt = build(
      :receipt,
      :failed,
      processing_error_code: 'ocr_api_error',
      processing_error_message: 'safe error'
    )
    attributes = {}

    described_class.call(receipt: receipt, attributes: attributes, review_state_arguments: nil)

    expect(attributes).to eq(
      'processing_error_code' => nil,
      'processing_error_message' => nil,
      'status' => 'completed'
    )
  end

  it 'does not replace an explicit status while clearing processing errors' do
    receipt = build(
      :receipt,
      :failed,
      processing_error_code: 'ocr_api_error',
      processing_error_message: 'safe error'
    )
    attributes = { 'status' => 'review_needed' }

    described_class.call(receipt: receipt, attributes: attributes, review_state_arguments: nil)

    expect(attributes).to include(
      'status' => 'review_needed',
      'processing_error_code' => nil,
      'processing_error_message' => nil
    )
  end

  it 'keeps a fallback processing error when a full-form rebuild would otherwise complete the receipt' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      review_reasons: [],
      processing_error_code: 'ai_unavailable',
      processing_error_message: 'safe fallback guidance'
    )
    attributes = { 'memo' => 'updated memo' }
    review_state_arguments = {
      amount_result: { review_reasons: [] },
      consistency_review_reasons: [],
      child_review_remaining: false,
      nested_amount_inputs_submitted: false,
      item_inputs_submitted: false
    }
    state = Receipts::Editing::ReviewState::Result.new(
      review_reasons: [],
      status: 'completed'
    )
    allow(Receipts::Editing::ReviewState).to receive(:call).and_return(state)

    described_class.call(
      receipt: receipt,
      attributes: attributes,
      review_state_arguments: review_state_arguments
    )

    expect(attributes).to eq(
      'memo' => 'updated memo',
      'review_reasons' => [],
      'status' => 'review_needed'
    )
  end

  it 'keeps a fallback processing error alongside warning-only review reasons' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'item_tax_rate_uncertain' ],
      processing_error_code: 'ai_unavailable',
      processing_error_message: 'safe fallback guidance'
    )
    attributes = {}
    review_state_arguments = {
      amount_result: { review_reasons: [ 'item_tax_rate_uncertain' ] },
      consistency_review_reasons: [],
      child_review_remaining: false,
      nested_amount_inputs_submitted: true,
      item_inputs_submitted: true
    }
    state = Receipts::Editing::ReviewState::Result.new(
      review_reasons: [ 'item_tax_rate_uncertain' ],
      status: 'completed'
    )
    allow(Receipts::Editing::ReviewState).to receive(:call).and_return(state)

    described_class.call(
      receipt: receipt,
      attributes: attributes,
      review_state_arguments: review_state_arguments
    )

    expect(attributes).to eq(
      'review_reasons' => [ 'item_tax_rate_uncertain' ],
      'status' => 'review_needed'
    )
  end

  it 'clears a processing error when child review still explains review_needed' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      review_reasons: [],
      processing_error_code: 'ai_unavailable',
      processing_error_message: 'safe fallback guidance'
    )
    attributes = {}
    review_state_arguments = {
      amount_result: { review_reasons: [] },
      consistency_review_reasons: [],
      child_review_remaining: true,
      nested_amount_inputs_submitted: false,
      item_inputs_submitted: false
    }
    state = Receipts::Editing::ReviewState::Result.new(
      review_reasons: [],
      status: 'review_needed'
    )
    allow(Receipts::Editing::ReviewState).to receive(:call).and_return(state)

    described_class.call(
      receipt: receipt,
      attributes: attributes,
      review_state_arguments: review_state_arguments
    )

    expect(attributes).to include(
      'review_reasons' => [],
      'status' => 'review_needed',
      'processing_error_code' => nil,
      'processing_error_message' => nil
    )
  end

  it 'clears a processing error after its previous blocking reason is resolved' do
    receipt = build(
      :receipt,
      status: 'review_needed',
      review_reasons: [ 'store_name_uncertain' ],
      processing_error_code: 'ai_unavailable',
      processing_error_message: 'safe fallback guidance'
    )
    attributes = {}
    review_state_arguments = {
      amount_result: { review_reasons: [] },
      consistency_review_reasons: [],
      child_review_remaining: false,
      nested_amount_inputs_submitted: false,
      item_inputs_submitted: false
    }
    state = Receipts::Editing::ReviewState::Result.new(
      review_reasons: [],
      status: 'completed'
    )
    allow(Receipts::Editing::ReviewState).to receive(:call).and_return(state)

    described_class.call(
      receipt: receipt,
      attributes: attributes,
      review_state_arguments: review_state_arguments
    )

    expect(attributes).to include(
      'review_reasons' => [],
      'status' => 'completed',
      'processing_error_code' => nil,
      'processing_error_message' => nil
    )
  end

  it 'leaves attributes unchanged when neither state transition applies' do
    receipt = build(:receipt, :completed, processing_error_code: nil, processing_error_message: nil)
    attributes = { 'memo' => 'unchanged' }

    result = described_class.call(receipt: receipt, attributes: attributes, review_state_arguments: nil)

    expect(result).to eq('memo' => 'unchanged')
  end
end
