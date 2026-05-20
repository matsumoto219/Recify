require 'rails_helper'

RSpec.describe Receipts::BatchUploadService, type: :service do
  let(:user) { create(:user) }

  def uploaded_receipt_fixture(filename = 'receipt_sample.jpg', content_type = 'image/jpeg')
    Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files', filename), content_type)
  end

  def invalid_uploaded_file
    Rack::Test::UploadedFile.new(
      Tempfile.create([ 'invalid-receipt-upload', '.txt' ]).tap { |file| file.write('dummy'); file.rewind }.path,
      'text/plain'
    )
  end

  before do
    allow(ReceiptAnalysisJob).to receive(:perform_later)
  end

  it '複数uploadの解析jobをreceipt_analysis queueへenqueueする' do
    allow(ReceiptAnalysisJob).to receive(:perform_later).and_call_original
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    files = [
      uploaded_receipt_fixture,
      uploaded_receipt_fixture('single_tax_receipt.png', 'image/png')
    ]

    result = described_class.call(user:, files:)

    enqueued_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == ReceiptAnalysisJob }

    aggregate_failures do
      expect(result).to be_success
      expect(enqueued_jobs.size).to eq(2)
      expect(enqueued_jobs.map { |job| job[:queue] }.uniq).to eq([ 'receipt_analysis' ])
    end
  ensure
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  it '1ファイルごとにreceiptを作成しcommit後に解析jobをenqueueする' do
    files = [
      uploaded_receipt_fixture,
      uploaded_receipt_fixture('single_tax_receipt.png', 'image/png')
    ]

    expect do
      result = described_class.call(user:, files:)

      aggregate_failures do
        expect(result).to be_success
        expect(result.count).to eq(2)
      end
    end.to change(user.receipts, :count).by(2)

    created_receipts = user.receipts.order(:id).last(2)

    aggregate_failures do
      expect(created_receipts).to all(be_processing)
      expect(created_receipts).to all(satisfy { |receipt| receipt.image.attached? })
      created_receipts.each do |receipt|
        expect(ReceiptAnalysisJob).to have_received(:perform_later).with(receipt.id)
      end
    end
  end

  it '空filesは失敗する' do
    result = described_class.call(user:, files: [])

    aggregate_failures do
      expect(result).not_to be_success
      expect(result.errors).to include(I18n.t('receipts.batch_upload.errors.empty'))
      expect(user.receipts.count).to eq(0)
      expect(ReceiptAnalysisJob).not_to have_received(:perform_later)
    end
  end

  it '最大件数を超える場合は失敗する' do
    files = Array.new(Receipts::BatchUploadService::MAX_FILES + 1) { uploaded_receipt_fixture }

    result = described_class.call(user:, files:)

    aggregate_failures do
      expect(result).not_to be_success
      expect(result.errors).to include(I18n.t('receipts.batch_upload.errors.too_many', max: Receipts::BatchUploadService::MAX_FILES))
      expect(user.receipts.count).to eq(0)
      expect(ReceiptAnalysisJob).not_to have_received(:perform_later)
    end
  end

  it '1件でもvalidation errorがあればall-or-nothingでrollbackする' do
    files = [
      uploaded_receipt_fixture,
      invalid_uploaded_file
    ]

    expect do
      result = described_class.call(user:, files:)

      aggregate_failures do
        expect(result).not_to be_success
        expect(result.errors.join).to include(I18n.t('activerecord.errors.models.receipt.attributes.image.invalid_content_type'))
      end
    end.not_to change(user.receipts, :count)

    expect(ReceiptAnalysisJob).not_to have_received(:perform_later)
  end

  it '合計サイズがストレージ残量を超える場合は失敗する' do
    files = [
      uploaded_receipt_fixture,
      uploaded_receipt_fixture
    ]
    user.update!(storage_limit_bytes: files.first.size + 1)

    result = described_class.call(user:, files:)

    aggregate_failures do
      expect(result).not_to be_success
      expect(result.errors).to include(I18n.t('receipts.batch_upload.errors.quota_exceeded'))
      expect(user.receipts.count).to eq(0)
      expect(ReceiptAnalysisJob).not_to have_received(:perform_later)
    end
  end
end
