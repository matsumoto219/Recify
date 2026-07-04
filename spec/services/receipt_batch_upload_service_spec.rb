require 'rails_helper'

RSpec.describe ReceiptBatchUploadService, type: :service do
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
    allow(ReceiptOcrJob).to receive(:perform_later)
  end

  it '複数uploadのOCR jobをreceipt_ocr queueへenqueueする' do
    allow(ReceiptOcrJob).to receive(:perform_later).and_call_original
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    files = [
      uploaded_receipt_fixture,
      uploaded_receipt_fixture('single_tax_receipt.png', 'image/png')
    ]

    result = described_class.call(user:, files:)

    enqueued_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == ReceiptOcrJob }

    aggregate_failures do
      expect(result).to be_success
      expect(enqueued_jobs.size).to eq(2)
      expect(enqueued_jobs.map { |job| job[:queue] }.uniq).to eq([ 'receipt_ocr' ])
    end
  ensure
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  it '1ファイルごとにreceiptとbatch_upload runを作成しcommit後にOCR jobをenqueueする' do
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
      .and change(ReceiptAnalysisRun, :count).by(2)

    created_receipts = user.receipts.order(:id).last(2)

    aggregate_failures do
      expect(created_receipts).to all(be_processing)
      expect(created_receipts).to all(satisfy { |receipt| receipt.image.attached? })
      expect(created_receipts).to all(have_attributes(
        processing_error_code: nil,
        processing_error_message: nil,
        review_reasons: []
      ))
      created_receipts.each do |receipt|
        run = receipt.receipt_analysis_runs.sole
        expect(run.source).to eq('batch_upload')
        expect(run.requested_by_user).to eq(user)
        expect(ReceiptOcrJob).to have_received(:perform_later).with(run_id: run.id)
      end
    end
  end

  it '成功時にfile数でbatch_files_per_dayを消費する' do
    files = [
      uploaded_receipt_fixture,
      uploaded_receipt_fixture('single_tax_receipt.png', 'image/png')
    ]

    result = described_class.call(user:, files:)

    counter = UsageCounter.find_by!(user: user, key: 'batch_files_per_day')

    aggregate_failures do
      expect(result).to be_success
      expect(counter.used_count).to eq(2)
    end
  end

  it 'userの画像保持設定を作成receiptへsnapshotする' do
    user.update!(keep_receipt_images: false)
    files = [
      uploaded_receipt_fixture,
      uploaded_receipt_fixture('single_tax_receipt.png', 'image/png')
    ]

    result = described_class.call(user:, files:)
    created_receipts = result.created_receipts

    aggregate_failures do
      expect(result).to be_success
      expect(created_receipts).to all(have_attributes(keep_image: false))
      expect(created_receipts).to all(have_attributes(image_purge_eligible_at: nil))
    end
  end

  it 'OCR job上限到達時も受付時にはrunを作成し、OCR jobをenqueueする' do
    create(:usage_counter, user: user, key: 'ocr_jobs_per_day', used_count: 50)
    files = [ uploaded_receipt_fixture ]

    result = described_class.call(user:, files:)
    run = user.receipts.order(:id).last.receipt_analysis_runs.sole

    aggregate_failures do
      expect(result).to be_success
      expect(run.status).to eq('queued')
      expect(run.error_stage).to be_nil
      expect(run.error_code).to be_nil
      expect(ReceiptOcrJob).to have_received(:perform_later).with(run_id: run.id)
      expect(UsageCounter.find_by!(user: user, key: 'ocr_jobs_per_day').used_count).to eq(50)
    end
  end

  it 'active runが既にあるreceiptはduplicate enqueueしない' do
    files = [ uploaded_receipt_fixture ]
    existing_run = instance_double(ReceiptAnalysisRun, id: 12_345)
    allow(ReceiptAnalysisRuns).to receive(:start).and_return(
      ReceiptAnalysisRuns::StartResult.new(run: existing_run, created: false)
    )

    result = described_class.call(user:, files:)

    aggregate_failures do
      expect(result).to be_success
      expect(result.count).to eq(1)
      expect(ReceiptAnalysisRuns).to have_received(:start).with(
        receipt: user.receipts.order(:id).last,
        source: 'batch_upload',
        requested_by_user: user
      )
      expect(ReceiptOcrJob).not_to have_received(:perform_later)
    end
  end

  it '空filesは失敗する' do
    result = described_class.call(user:, files: [])

    aggregate_failures do
      expect(result).not_to be_success
      expect(result.errors).to include(I18n.t('receipts.batch_upload.errors.empty'))
      expect(user.receipts.count).to eq(0)
      expect(ReceiptOcrJob).not_to have_received(:perform_later)
    end
  end

  it 'OCR停止中はreceipt作成とcounter消費を行わず拒否する' do
    create(:system_setting, key: 'operations.ocr_enabled', value: SystemSettings.stored_value(false))
    files = [
      uploaded_receipt_fixture,
      uploaded_receipt_fixture('single_tax_receipt.png', 'image/png')
    ]

    expect do
      result = described_class.call(user:, files:)

      aggregate_failures do
        expect(result).not_to be_success
        expect(result.errors).to include(I18n.t('flash.receipts.ocr_unavailable'))
      end
    end.not_to change(user.receipts, :count)

    aggregate_failures do
      expect(ReceiptAnalysisRun.count).to eq(0)
      expect(UsageCounter.where(user: user)).to be_empty
      expect(ReceiptOcrJob).not_to have_received(:perform_later)
    end
  end

  it '最大件数を超える場合は失敗する' do
    files = Array.new(ReceiptBatchUploadService.max_files + 1) { uploaded_receipt_fixture }

    result = described_class.call(user:, files:)

    aggregate_failures do
      expect(result).not_to be_success
      expect(result.errors).to include(I18n.t('receipts.batch_upload.errors.too_many', max: ReceiptBatchUploadService.max_files))
      expect(user.receipts.count).to eq(0)
      expect(ReceiptOcrJob).not_to have_received(:perform_later)
    end
  end

  it 'SystemSettingsの最大件数を適用する' do
    create(:system_setting, key: 'limits.batch_upload_max_files', value: SystemSettings.stored_value(10))
    allowed_files = Array.new(10) { uploaded_receipt_fixture }
    too_many_files = Array.new(11) { uploaded_receipt_fixture }

    allowed_result = described_class.call(user:, files: allowed_files)
    too_many_result = described_class.call(user:, files: too_many_files)

    aggregate_failures do
      expect(described_class.max_files).to eq(10)
      expect(allowed_result).to be_success
      expect(allowed_result.count).to eq(10)
      expect(too_many_result).not_to be_success
      expect(too_many_result.errors).to include(I18n.t('receipts.batch_upload.errors.too_many', max: 10))
    end
  end

  it 'SystemSettingsの最大値20件まで許可し21件は拒否する' do
    create(:system_setting, key: 'limits.batch_upload_max_files', value: SystemSettings.stored_value(20))
    allowed_files = Array.new(20) { uploaded_receipt_fixture }
    too_many_files = Array.new(21) { uploaded_receipt_fixture }

    allowed_result = described_class.call(user:, files: allowed_files)
    too_many_result = described_class.call(user:, files: too_many_files)

    aggregate_failures do
      expect(described_class.max_files).to eq(20)
      expect(allowed_result).to be_success
      expect(allowed_result.count).to eq(20)
      expect(too_many_result).not_to be_success
      expect(too_many_result.errors).to include(I18n.t('receipts.batch_upload.errors.too_many', max: 20))
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

    expect(ReceiptOcrJob).not_to have_received(:perform_later)
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
      expect(ReceiptOcrJob).not_to have_received(:perform_later)
    end
  end

  it '全体storage hard stop超過時はall-or-nothingで拒否する' do
    files = [
      uploaded_receipt_fixture,
      uploaded_receipt_fixture
    ]
    allow(Storage).to receive(:global_quota_can_add?).and_return(false)

    result = described_class.call(user:, files:)

    aggregate_failures do
      expect(result).not_to be_success
      expect(result.errors).to include(I18n.t('receipts.batch_upload.errors.global_hard_stop'))
      expect(user.receipts.count).to eq(0)
      expect(ReceiptOcrJob).not_to have_received(:perform_later)
    end
  end

  it 'batch_files_per_day上限到達時はall-or-nothingで拒否する' do
    files = [
      uploaded_receipt_fixture,
      uploaded_receipt_fixture('single_tax_receipt.png', 'image/png')
    ]
    create(:usage_counter, user: user, key: 'batch_files_per_day', used_count: 49)

    result = described_class.call(user:, files:)

    aggregate_failures do
      expect(result).not_to be_success
      expect(result.errors).to include(I18n.t('receipts.batch_upload.errors.usage_limit_exceeded'))
      expect(user.receipts.count).to eq(0)
      expect(ReceiptOcrJob).not_to have_received(:perform_later)
      expect(UsageCounter.find_by!(user: user, key: 'batch_files_per_day').used_count).to eq(49)
    end
  end

  it '一括アップロード上限を増やしても日次batch/OCR/AI/upload quotaは独立して動作する' do
    create(:system_setting, key: 'limits.batch_upload_max_files', value: SystemSettings.stored_value(20))
    files = Array.new(20) { uploaded_receipt_fixture }

    first_result = described_class.call(user:, files:)
    batch_counter = UsageCounter.find_by!(user: user, key: 'batch_files_per_day')
    batch_counter.update!(used_count: 40)
    blocked_result = described_class.call(user:, files:)

    aggregate_failures do
      expect(first_result).to be_success
      expect(first_result.count).to eq(20)
      expect(UsageCounter.find_by!(user: user, key: 'batch_files_per_day').used_count).to eq(40)
      expect(UsageCounter.where(user: user, key: 'ocr_jobs_per_day')).to be_empty
      expect(UsageCounter.where(user: user, key: 'receipt_uploads_per_day')).to be_empty
      expect(UsageCounter.where(user: user, key: 'ai_jobs_per_day')).to be_empty
      expect(blocked_result).not_to be_success
      expect(blocked_result.errors).to include(I18n.t('receipts.batch_upload.errors.usage_limit_exceeded'))
      expect(user.receipts.count).to eq(20)
      expect(ReceiptOcrJob).to have_received(:perform_later).exactly(20).times
    end
  end

  it 'guest batchはguest用batch_files_per_dayを適用する' do
    guest = create(:user, guest: true)
    files = [ uploaded_receipt_fixture ]

    result = described_class.call(user: guest, files: files)

    aggregate_failures do
      expect(result).to be_success
      expect(UsageCounter.find_by!(user: guest, key: 'batch_files_per_day').used_count).to eq(1)
      expect(UsageCounter.where(user: guest, key: 'guest_receipt_uploads_per_day')).to be_empty
    end
  end

  it 'guest batchは6ファイル相当になる場合にall-or-nothingで拒否する' do
    guest = create(:user, guest: true)
    files = [
      uploaded_receipt_fixture,
      uploaded_receipt_fixture('single_tax_receipt.png', 'image/png')
    ]
    create(:usage_counter, user: guest, key: 'batch_files_per_day', used_count: 4)

    result = described_class.call(user: guest, files: files)

    aggregate_failures do
      expect(result).not_to be_success
      expect(result.errors).to include(I18n.t('receipts.batch_upload.errors.usage_limit_exceeded'))
      expect(guest.receipts.count).to eq(0)
      expect(ReceiptOcrJob).not_to have_received(:perform_later)
      expect(UsageCounter.find_by!(user: guest, key: 'batch_files_per_day').used_count).to eq(4)
    end
  end
end
