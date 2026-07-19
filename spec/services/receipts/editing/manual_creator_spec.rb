require 'rails_helper'

RSpec.describe Receipts::Editing::ManualCreator, type: :service do
  let(:user) { create(:user) }
  let(:receipt) { user.receipts.new }
  let(:attributes) do
    {
      'store_name' => 'テスト店',
      'total_amount' => 1000,
      'payment_method' => 'cash',
      'review_reasons' => [],
      'receipt_items_attributes' => {
        '0' => {
          'confirmed_name' => '商品',
          'price' => 1000,
          'quantity' => 1,
          'quantity_unit_code' => 'each',
          'line_total' => 1000,
          'needs_review' => false
        }
      }
    }
  end

  it 'saves a completed manual receipt and consumes usage atomically' do
    result = described_class.call(
      receipt: receipt,
      attributes: attributes,
      user: user,
      items_missing: false
    )

    aggregate_failures do
      expect(result).to be_saved
      expect(result).not_to be_items_missing
      expect(result.receipt).to be_completed
      expect(result.receipt).to be_persisted
      expect(UsageCounter.find_by!(user: user, key: 'manual_receipts_per_day').used_count).to eq(1)
      expect(result.receipt.receipt_items.sole.confirmed_name).to eq('商品')
    end
  end

  it 'uses review_needed when blocking review reasons remain' do
    attributes['review_reasons'] = [ 'total_mismatch' ]

    result = described_class.call(
      receipt: receipt,
      attributes: attributes,
      user: user,
      items_missing: false
    )

    expect(result.receipt).to be_review_needed
    expect(result.receipt.review_reasons).to eq([ 'total_mismatch' ])
  end

  it 'assigns status and attributes but does not validate or consume usage when items are missing' do
    attributes['receipt_items_attributes'] = {}

    result = described_class.call(
      receipt: receipt,
      attributes: attributes,
      user: user,
      items_missing: true
    )

    aggregate_failures do
      expect(result).not_to be_saved
      expect(result).to be_items_missing
      expect(result.receipt).to be_completed
      expect(result.receipt.store_name).to eq('テスト店')
      expect(result.receipt).not_to be_persisted
      expect(UsageCounter.where(user: user, key: 'manual_receipts_per_day')).to be_empty
    end
  end

  it 'does not consume usage when validation fails' do
    create(:usage_counter, user: user, key: 'manual_receipts_per_day', used_count: 4)
    attributes['memo'] = 'x' * 1001

    result = described_class.call(
      receipt: receipt,
      attributes: attributes,
      user: user,
      items_missing: false
    )

    aggregate_failures do
      expect(result).not_to be_saved
      expect(result.receipt.errors).to be_present
      expect(UsageCounter.find_by!(user: user, key: 'manual_receipts_per_day').used_count).to eq(4)
    end
  end

  it 'lets usage limit errors propagate without persisting the receipt' do
    error = Usage::LimitExceeded.new(key: 'manual_receipts_per_day', limit: 0, used: 0, requested: 1)
    allow(Usage).to receive(:consume_manual_receipt!).and_raise(error)

    expect do
      described_class.call(
        receipt: receipt,
        attributes: attributes,
        user: user,
        items_missing: false
      )
    end.to raise_error(Usage::LimitExceeded)
    expect(receipt).not_to be_persisted
  end

  it 'preserves image retention attributes and never starts analysis' do
    attributes['keep_image'] = false
    attributes['image_purge_eligible_at'] = Time.zone.parse('2026-07-12 10:00')
    allow(Receipts::Processing).to receive(:start)

    result = described_class.call(
      receipt: receipt,
      attributes: attributes,
      user: user,
      items_missing: false
    )

    aggregate_failures do
      expect(result.receipt).to have_attributes(
        keep_image: false,
        image_purge_eligible_at: Time.zone.parse('2026-07-12 10:00')
      )
      expect(Receipts::Processing).not_to have_received(:start)
    end
  end

  it 'lock後のquota再判定で超過した画像を保存せずusageも消費しない' do
    attributes['image'] = Rack::Test::UploadedFile.new(
      Rails.root.join('spec/fixtures/files/receipt_sample.jpg'),
      'image/jpeg'
    )
    allow(Storage).to receive(:with_quota_reservation)
      .and_raise(Storage::QuotaExceeded.new(scope: :user))

    result = described_class.call(
      receipt: receipt,
      attributes: attributes,
      user: user,
      items_missing: false
    )

    aggregate_failures do
      expect(result).not_to be_saved
      expect(result.receipt.errors).to be_of_kind(:image, :storage_quota_exceeded)
      expect(result.receipt).not_to be_persisted
      expect(UsageCounter.where(user: user, key: 'manual_receipts_per_day')).to be_empty
    end
  end
end
