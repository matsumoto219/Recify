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

  describe '.reset_for_retry!' do
    let(:receipt) do
      create(
        :receipt,
        :completed,
        :with_image,
        memo: '利用者メモ',
        subtotal_amount: 1000,
        tax_amount: 100,
        total_amount: 1100,
        tax_rate: '0.1',
        tip_amount: 0,
        receipt_type: 'Itemized',
        currency_code: 'JPY',
        store_address: 'テスト住所',
        store_phone_number: '03-0000-0000',
        ocr_completed_at: Time.current,
        amount_calculation_profile: { 'schema_version' => 'test' }
      )
    end

    before do
      receipt.receipt_items.create!(
        confirmed_name: '手動確定商品',
        quantity: 1,
        price: 1000,
        line_total: 1000,
        original_line_total: 1000,
        pricing_source_kind: 'explicit_line_total'
      )
      receipt.receipt_tax_details.create!(rate: '0.1', net_amount: 1000, amount: 100)
      receipt.receipt_payments.create!(method: 'cash', amount: 1100)
      create(:receipt_adjustment, receipt:)
    end

    it 'clears previous analysis including manual item authority while retaining upload identity and memo' do
      retained = receipt.attributes.slice('user_id', 'public_id', 'display_id', 'memo', 'keep_image', 'created_at')
      blob_id = receipt.image.blob.id

      described_class.reset_for_retry!(receipt)

      aggregate_failures do
        expect(receipt.reload.attributes.slice(*retained.keys)).to eq(retained)
        expect(receipt.image.blob.id).to eq(blob_id)
        expect(receipt).to have_attributes(
          status: 'processing',
          store_name: nil,
          store_address: nil,
          store_phone_number: nil,
          purchased_at: nil,
          payment_method: nil,
          subtotal_amount: nil,
          tax_amount: nil,
          total_amount: nil,
          tax_rate: nil,
          tip_amount: nil,
          receipt_type: nil,
          currency_code: nil,
          ocr_completed_at: nil,
          store_address_components: {},
          amount_calculation_profile: {},
          review_reasons: []
        )
        %i[receipt_items receipt_tax_details receipt_payments receipt_adjustments].each do |association_name|
          expect(receipt.public_send(association_name)).to be_empty
        end
      end
    end

    it 'rolls back scalar and child resets when the enclosing retry operation fails' do
      original = receipt.attributes
      item_id = receipt.receipt_items.sole.id

      Receipt.transaction do
        described_class.reset_for_retry!(receipt)
        raise ActiveRecord::Rollback
      end

      expect(receipt.reload.attributes).to eq(original)
      expect(receipt.receipt_items.sole.id).to eq(item_id)
      expect(receipt.receipt_tax_details.count).to eq(1)
      expect(receipt.receipt_payments.count).to eq(1)
      expect(receipt.receipt_adjustments.count).to eq(1)
    end

    it 'preserves children if saving the reset receipt fails' do
      item_id = receipt.receipt_items.sole.id
      allow(receipt).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(receipt))

      expect { described_class.reset_for_retry!(receipt) }.to raise_error(ActiveRecord::RecordInvalid)

      expect(receipt.reload).to be_completed
      expect(receipt.receipt_items.sole.id).to eq(item_id)
    end
  end
end
