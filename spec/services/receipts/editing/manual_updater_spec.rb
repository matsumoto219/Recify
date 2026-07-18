require 'rails_helper'

RSpec.describe Receipts::Editing::ManualUpdater do
  let(:user) { create(:user) }
  let(:receipt) { create(:receipt, :completed, user: user, memo: 'before') }

  it 'persists valid manual update attributes' do
    result = described_class.call(
      receipt: receipt,
      attributes: { 'memo' => 'after' },
      items_missing: false
    )

    aggregate_failures do
      expect(result).to be_saved
      expect(result).not_to be_items_missing
      expect(result.receipt).to equal(receipt)
      expect(receipt.reload.memo).to eq('after')
    end
  end

  it 'returns the error-bearing receipt when validation fails' do
    result = described_class.call(
      receipt: receipt,
      attributes: { 'memo' => 'x' * 1001 },
      items_missing: false
    )

    aggregate_failures do
      expect(result).not_to be_saved
      expect(result.receipt.errors[:memo]).to be_present
      expect(receipt.reload.memo).to eq('before')
    end
  end

  it 'validation失敗時は保存用derived attrsから元のsource attrsへ戻してerrorを維持する' do
    item = receipt.receipt_items.create!(
      confirmed_name: '商品', price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100
    )
    source_attributes = {
      'store_name' => '',
      'receipt_items_attributes' => {
        '0' => { 'id' => item.id.to_s, 'price' => 100, 'line_total' => 100 }
      }
    }
    source_snapshot = source_attributes.deep_dup

    result = described_class.call(
      receipt: receipt,
      attributes: {
        'store_name' => '',
        'receipt_items_attributes' => {
          '0' => { 'id' => item.id.to_s, 'price' => 110, 'line_total' => 110 }
        }
      },
      source_attributes: source_attributes,
      items_missing: false
    )

    aggregate_failures do
      expect(result).not_to be_saved
      expect(result.receipt.errors[:store_name]).to be_present
      expect(result.receipt.receipt_items.first.price).to eq(100)
      expect(result.receipt.receipt_items.first.line_total).to eq(100)
      expect(source_attributes).to eq(source_snapshot)
      expect(item.reload.price).to eq(100)
    end
  end

  it 'assigns attributes without persistence for the missing-item render path' do
    result = described_class.call(
      receipt: receipt,
      attributes: { 'memo' => 'in memory' },
      items_missing: true
    )

    aggregate_failures do
      expect(result).not_to be_saved
      expect(result).to be_items_missing
      expect(receipt.memo).to eq('in memory')
      expect(receipt.reload.memo).to eq('before')
    end
  end

  it 'propagates optimistic locking conflicts to the HTTP boundary' do
    allow(receipt).to receive(:update).and_raise(ActiveRecord::StaleObjectError.new(receipt, 'update'))

    expect do
      described_class.call(
        receipt: receipt,
        attributes: { 'memo' => 'after' },
        items_missing: false
      )
    end.to raise_error(ActiveRecord::StaleObjectError)
  end

  it 'does not consume manual creation usage' do
    allow(Usage).to receive(:consume_manual_receipt!)

    described_class.call(
      receipt: receipt,
      attributes: { 'memo' => 'after' },
      items_missing: false
    )

    expect(Usage).not_to have_received(:consume_manual_receipt!)
  end

  it 'lock後のquota再判定で超過した画像差し替えを保存しない' do
    uploaded_image = Rack::Test::UploadedFile.new(
      Rails.root.join('spec/fixtures/files/receipt_sample.jpg'),
      'image/jpeg'
    )
    allow(Storage).to receive(:with_quota_reservation)
      .and_raise(Storage::QuotaExceeded.new(scope: :global))

    result = described_class.call(
      receipt: receipt,
      attributes: { 'image' => uploaded_image },
      items_missing: false
    )

    aggregate_failures do
      expect(result).not_to be_saved
      expect(result.receipt.errors).to be_of_kind(:image, :storage_quota_exceeded)
      expect(result.receipt.errors[:image].size).to eq(1)
      expect(receipt.reload.image).not_to be_attached
    end
  end
end
