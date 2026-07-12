require 'rails_helper'

RSpec.describe Receipts::Uploads::Single, type: :service do
  let(:user) { create(:user) }

  def uploaded_receipt_fixture
    Rack::Test::UploadedFile.new(
      Rails.root.join('spec/fixtures/files/receipt_sample.jpg'),
      'image/jpeg'
    )
  end

  def invalid_uploaded_file
    Rack::Test::UploadedFile.new(
      Tempfile.create([ 'invalid-receipt-upload', '.txt' ]).tap do |file|
        file.write('dummy')
        file.rewind
      end.path,
      'text/plain'
    )
  end

  before do
    allow(ReceiptOcrJob).to receive(:perform_later)
    allow(Receipts::Processing).to receive(:start).and_call_original
  end

  it 'creates a processing receipt and enqueues analysis after persistence' do
    allow(Receipts::Processing).to receive(:start).and_wrap_original do |method, **arguments|
      expect(arguments.fetch(:receipt)).to be_persisted
      method.call(**arguments)
    end

    result = described_class.call(user: user, image: uploaded_receipt_fixture)
    receipt = result.receipt
    run = receipt.receipt_analysis_runs.sole

    aggregate_failures do
      expect(result).to be_saved
      expect(result).to be_enqueue_succeeded
      expect(receipt).to be_processing
      expect(receipt.image).to be_attached
      expect(run).to have_attributes(source: 'upload', requested_by_user: user, status: 'queued')
      expect(ReceiptOcrJob).to have_received(:perform_later).with(run_id: run.id)
      expect(UsageCounter.find_by!(user: user, key: 'receipt_uploads_per_day').used_count).to eq(1)
    end
  end

  it 'snapshots the image retention preference' do
    user.update!(keep_receipt_images: false)

    result = described_class.call(user: user, image: uploaded_receipt_fixture)

    expect(result.receipt).to have_attributes(keep_image: false, image_purge_eligible_at: nil)
  end

  it 'rolls back usage when receipt validation fails and returns its errors' do
    create(:usage_counter, user: user, key: 'receipt_uploads_per_day', used_count: 3)

    result = described_class.call(user: user, image: invalid_uploaded_file)

    aggregate_failures do
      expect(result).not_to be_saved
      expect(result).not_to be_enqueue_succeeded
      expect(result.receipt).not_to be_persisted
      expect(result.receipt.errors[:image]).to be_present
      expect(UsageCounter.find_by!(user: user, key: 'receipt_uploads_per_day').used_count).to eq(3)
      expect(Receipts::Processing).not_to have_received(:start)
      expect(ReceiptOcrJob).not_to have_received(:perform_later)
    end
  end

  it 'lock後のquota再判定で超過した場合はreceiptもusageも保存しない' do
    allow(Storage).to receive(:with_quota_reservation)
      .and_raise(Storage::QuotaExceeded.new(scope: :global))

    result = described_class.call(user: user, image: uploaded_receipt_fixture)

    aggregate_failures do
      expect(result).not_to be_saved
      expect(result.receipt.errors).to be_of_kind(:image, :storage_quota_exceeded)
      expect(user.receipts.reload).to be_empty
      expect(UsageCounter.where(user: user, key: 'receipt_uploads_per_day')).to be_empty
      expect(Receipts::Processing).not_to have_received(:start)
    end
  end

  it 'lets the public usage limit error propagate without creating a receipt' do
    error = Usage::LimitExceeded.new(key: 'receipt_uploads_per_day', limit: 0, used: 0, requested: 1)
    allow(Usage).to receive(:consume_receipt_upload!).and_raise(error)
    receipt_count = Receipt.count

    expect do
      described_class.call(user: user, image: uploaded_receipt_fixture)
    end.to raise_error(Usage::LimitExceeded)
    expect(Receipt.count).to eq(receipt_count)
  end

  it 'reports enqueue failure after Processing compensates receipt and run status' do
    allow(ReceiptOcrJob).to receive(:perform_later).and_raise(StandardError, 'queue unavailable')

    result = described_class.call(user: user, image: uploaded_receipt_fixture)
    receipt = result.receipt
    run = receipt.receipt_analysis_runs.sole

    aggregate_failures do
      expect(result).to be_saved
      expect(result).not_to be_enqueue_succeeded
      expect(receipt.reload).to have_attributes(status: 'failed', processing_error_code: 'analysis_enqueue_failed')
      expect(run.reload).to have_attributes(status: 'failed', error_stage: 'enqueue', error_code: 'analysis_enqueue_failed')
    end
  end

  it 'does not enqueue a duplicate job when Processing returns an active run' do
    existing_run = instance_double(ReceiptAnalysisRun, id: 12_345)
    allow(Receipts::Processing).to receive(:start).and_return(
      Receipts::Processing::StartResult.new(run: existing_run, created: false)
    )

    result = described_class.call(user: user, image: uploaded_receipt_fixture)

    aggregate_failures do
      expect(result).to be_saved
      expect(result).to be_enqueue_succeeded
      expect(ReceiptOcrJob).not_to have_received(:perform_later)
    end
  end
end
