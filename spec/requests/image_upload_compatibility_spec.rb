require 'rails_helper'
require 'tmpdir'

RSpec.describe 'Image upload compatibility', type: :request do
  let(:user) { create(:user) }
  let(:hdr_path) { Rails.root.join('spec/fixtures/files/readable_hdr_image.jpg') }
  let(:hdr_bytes) { File.binread(hdr_path) }

  around do |example|
    Dir.mktmpdir('recify-image-compatibility-spec') do |directory|
      @service = ActiveStorage::Service::DiskService.new(root: directory)
      @service.name = 'test'
      example.run
    end
  end

  before do
    allow(ActiveStorage::Blob).to receive(:service).and_return(@service)
    allow(ActiveStorage::Blob.services).to receive(:fetch).with('test').and_return(@service)
    allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
    allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
    allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
    allow(ReceiptOcrJob).to receive(:perform_later)
    expect(ReceiptOcrService).not_to receive(:call)
    expect(ReceiptAiEnrichmentService).not_to receive(:call)
    sign_in user
  end

  def uploaded_hdr
    Rack::Test::UploadedFile.new(hdr_path, 'image/jpeg')
  end

  def uploaded_fixture(filename, content_type)
    Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files', filename), content_type)
  end

  def with_uploaded_bytes(bytes, extension:, content_type:)
    Tempfile.create([ 'synthetic-image', extension ]) do |file|
      file.binmode
      file.write(bytes)
      file.rewind
      yield Rack::Test::UploadedFile.new(file.path, content_type)
    end
  end

  def invalid_upload_events
    SecurityEvent.where(event_type: 'invalid_upload', actor_user: user).order(:id).to_a
  end

  def usage_counts
    UsageCounter.where(user: user).pluck(:key, :used_count).to_h
  end

  def expect_original_hdr(attachment)
    aggregate_failures do
      expect(attachment).to be_attached
      expect(attachment.blob.content_type).to eq('image/jpeg')
      expect(attachment.blob.metadata).to include('width' => 120, 'height' => 160, 'analyzed' => true)
      expect(attachment.download).to eq(hdr_bytes)
    end
  end

  def expect_queued_analysis(receipt, source:)
    run = receipt.receipt_analysis_runs.sole
    aggregate_failures do
      expect(receipt).to be_processing
      expect(run).to have_attributes(source: source, requested_by_user: user, status: 'queued')
      expect(ReceiptOcrJob).to have_received(:perform_later).with(run_id: run.id).once
    end
  end

  it '単一OCR登録で正常なHDR JPEGを変換せず保存し、受付と解析開始を1回ずつ行う' do
    post upload_receipts_path, params: {
      receipt_registration_token: Receipts::Registrations.issue_token(user: user, kind: 'upload'),
      receipt: { image: uploaded_hdr }
    }

    receipt = user.receipts.sole
    aggregate_failures do
      expect(response).to redirect_to(receipts_path)
      expect_original_hdr(receipt.image)
      expect_queued_analysis(receipt, source: 'upload')
      expect(usage_counts).to eq('receipt_uploads_per_day' => 1)
      expect(user.reload.storage_used_bytes).to eq(hdr_bytes.bytesize)
    end
  end

  it '一括OCR登録ではHDR JPEGと通常PNGの全件を保存し、画像枚数だけ利用回数を加算する' do
    png_path = Rails.root.join('spec/fixtures/files/single_tax_receipt.png')
    post upload_receipts_path, params: {
      receipt_registration_token: Receipts::Registrations.issue_token(user: user, kind: 'upload'),
      receipt: { images: [ uploaded_hdr, uploaded_fixture('single_tax_receipt.png', 'image/png') ] }
    }

    receipts = user.receipts.order(:id).to_a
    aggregate_failures do
      expect(response).to redirect_to(receipts_path)
      expect(receipts.size).to eq(2)
      expect_original_hdr(receipts.first.image)
      expect(receipts.last.image.download).to eq(File.binread(png_path))
      receipts.each { |receipt| expect_queued_analysis(receipt, source: 'batch_upload') }
      expect(ReceiptOcrJob).to have_received(:perform_later).twice
      expect(usage_counts).to eq('batch_files_per_day' => 2)
      expect(user.reload.storage_used_bytes).to eq(hdr_bytes.bytesize + png_path.size)
    end
  end

  it '一括OCR登録に破損したJPEGが1枚あれば正常なHDR JPEGも含めて受付しない' do
    Tempfile.create([ 'truncated-image', '.jpg' ]) do |file|
      file.binmode
      file.write(hdr_bytes.byteslice(0, hdr_bytes.bytesize / 2))
      file.rewind

      post upload_receipts_path, params: {
        receipt_registration_token: Receipts::Registrations.issue_token(user: user, kind: 'upload'),
        receipt: { images: [ uploaded_hdr, Rack::Test::UploadedFile.new(file.path, 'image/jpeg') ] }
      }
    end

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('activerecord.errors.models.receipt.attributes.image.unreadable_image'))
      expect(user.receipts.reload).to be_empty
      expect(ReceiptAnalysisRun.count).to eq(0)
      expect(ActiveStorage::Attachment.count).to eq(0)
      expect(ActiveStorage::Blob.count).to eq(0)
      expect(usage_counts).to be_empty
      expect(ReceiptOcrJob).not_to have_received(:perform_later)
      expect(Dir.glob(File.join(@service.root, '**', '*')).select { |path| File.file?(path) }).to be_empty
      expect(invalid_upload_events.size).to eq(2)
      expect(invalid_upload_events.map(&:matched_rule)).to eq(%w[unreadable_image unreadable_image])
      expect(invalid_upload_events.map { |event| event.metadata['reason'] }).to eq(%w[unreadable_image unreadable_image])
    end
  end

  it '単一OCR登録の読取不能を固定reasonで記録し、受付と利用回数を増やさない' do
    with_uploaded_bytes(hdr_bytes.byteslice(0, hdr_bytes.bytesize / 2), extension: '.jpg', content_type: 'image/jpeg') do |image|
      post upload_receipts_path, params: {
        receipt_registration_token: Receipts::Registrations.issue_token(user: user, kind: 'upload'),
        receipt: { image: image }
      }
    end

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(invalid_upload_events.sole).to have_attributes(field_name: 'receipt.image', matched_rule: 'unreadable_image')
      expect(invalid_upload_events.sole.metadata).to include('reason' => 'unreadable_image')
      expect(user.receipts.reload).to be_empty
      expect(ActiveStorage::Blob.count).to eq(0)
      expect(usage_counts).to be_empty
      expect(ReceiptOcrJob).not_to have_received(:perform_later)
    end
  end

  %i[image images].each do |field|
    it "OCR登録の#{field}経路で総画素上限の拒否を固定reasonで記録する" do
      image = Vips::Image.black(120, 160, bands: 3)
      bytes = image.join(image, :vertical).tiffsave_buffer(page_height: 160)
      allow(Receipt).to receive(:image_max_dimension).and_return(160)

      with_uploaded_bytes(bytes, extension: '.tiff', content_type: 'image/tiff') do |upload|
        post upload_receipts_path, params: {
          receipt_registration_token: Receipts::Registrations.issue_token(user: user, kind: 'upload'),
          receipt: { field => field == :images ? [ upload ] : upload }
        }
      end

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(invalid_upload_events.sole).to have_attributes(field_name: 'receipt.image', matched_rule: 'image_pixel_limit_exceeded')
        expect(invalid_upload_events.sole.metadata).to include('reason' => 'image_pixel_limit_exceeded')
        expect(user.receipts.reload).to be_empty
        expect(ActiveStorage::Blob.count).to eq(0)
        expect(usage_counts).to be_empty
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end
  end

  it '手動登録のHDR JPEGは画像を保持してmanual counterだけを加算する' do
    context = Receipts::CalculationContext.build(user: user, receipt: Receipt.new(user: user))
    post receipts_path, params: {
      receipt_registration_token: Receipts::Registrations.issue_token(user: user, kind: 'manual'),
      receipt_calculation_context: context.token,
      receipt: {
        store_name: '合成画像検証店',
        total_amount: 1000,
        payment_method: 'cash',
        image: uploaded_hdr,
        receipt_items_attributes: {
          '0' => {
            confirmed_name: '検証品', price: 1000, quantity: 1,
            quantity_unit_code: 'each', line_total: 1000, needs_review: false
          }
        }
      }
    }

    receipt = user.receipts.sole
    aggregate_failures do
      expect(response).to redirect_to(receipts_path)
      expect(receipt).to be_completed
      expect_original_hdr(receipt.image)
      expect(receipt.receipt_analysis_runs).to be_empty
      expect(usage_counts).to eq('manual_receipts_per_day' => 1)
      expect(ReceiptOcrJob).not_to have_received(:perform_later)
    end
  end

  it '既存レシートへのHDR JPEG追加で解析と登録回数を増やさない' do
    receipt = create(:receipt, :completed, user: user)

    patch receipt_path(receipt), params: {
      receipt: { lock_version: receipt.lock_version, image: uploaded_hdr }
    }

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect_original_hdr(receipt.reload.image)
      expect(receipt.receipt_analysis_runs).to be_empty
      expect(usage_counts).to be_empty
      expect(ReceiptOcrJob).not_to have_received(:perform_later)
    end
  end

  it '既存レシート画像をHDR JPEGへ差し替えても画像以外の値と利用回数を維持する' do
    receipt = create(:receipt, :completed, :with_image, user: user, memo: '画像以外は変更なし')
    original_blob_id = receipt.image.blob.id

    patch receipt_path(receipt), params: {
      receipt: { lock_version: receipt.lock_version, image: uploaded_hdr }
    }

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect_original_hdr(receipt.reload.image)
      expect(receipt.image.blob.id).not_to eq(original_blob_id)
      expect(receipt.memo).to eq('画像以外は変更なし')
      expect(receipt.total_amount).to eq(1000)
      expect(receipt.receipt_analysis_runs).to be_empty
      expect(usage_counts).to be_empty
      expect(ReceiptOcrJob).not_to have_received(:perform_later)
    end
  end

  it 'プロフィール画像をHDR JPEGへ差し替え、レシート用利用回数と解析を増やさない' do
    user.avatar.attach(uploaded_fixture('receipt_sample.jpg', 'image/jpeg'))
    original_blob_id = user.avatar.blob.id

    patch user_registration_path, params: {
      update_context: 'account',
      user: { name: '画像互換性確認', avatar: uploaded_hdr }
    }

    aggregate_failures do
      expect(response).to redirect_to(settings_path)
      expect_original_hdr(user.reload.avatar)
      expect(user.avatar.blob.id).not_to eq(original_blob_id)
      expect(user.name).to eq('画像互換性確認')
      expect(user.receipts).to be_empty
      expect(usage_counts).to be_empty
      expect(ReceiptOcrJob).not_to have_received(:perform_later)
    end
  end

  context 'adminのお知らせ登録' do
    let(:user) { create(:user, :admin) }

    %w[unreadable_image image_pixel_limit_exceeded].each do |reason|
      it "画像の#{reason}を記録し、旧画像と監査の成功条件を維持する" do
        announcement = create(:announcement, image_alt_text: '既存画像')
        announcement.image.attach(uploaded_fixture('receipt_sample.jpg', 'image/jpeg'))
        old_blob = announcement.image.blob
        old_bytes = announcement.image.download
        if reason == 'unreadable_image'
          bytes = hdr_bytes.byteslice(0, hdr_bytes.bytesize / 2)
          extension, content_type = '.jpg', 'image/jpeg'
        else
          image = Vips::Image.black(120, 160, bands: 3)
          bytes = image.join(image + 255, :vertical).webpsave_buffer(page_height: 160, lossless: true)
          extension, content_type = '.webp', 'image/webp'
          allow(Announcement).to receive(:image_max_dimension).and_return(160)
        end

        with_uploaded_bytes(bytes, extension: extension, content_type: content_type) do |upload|
          patch admin_announcement_path(announcement), params: {
            announcement: { image: upload, image_alt_text: '差し替え画像' }
          }
        end

        aggregate_failures do
          expect(response).to have_http_status(:unprocessable_content)
          expect(announcement.reload.image.blob).to eq(old_blob)
          expect(announcement.image.download).to eq(old_bytes)
          expect(ActiveStorage::Blob.count).to eq(1)
          expect(invalid_upload_events.sole).to have_attributes(field_name: 'announcement.image', matched_rule: reason)
          expect(invalid_upload_events.sole.metadata).to include('reason' => reason)
          expect(invalid_upload_events.sole.metadata.to_json).not_to include('Vips::Error', '/tmp/', 'signed_id')
          expect(AuditLog.where(action: 'announcement.update', actor_user: user)).to be_empty
          expect(usage_counts).to be_empty
          expect(ReceiptOcrJob).not_to have_received(:perform_later)
        end
      end
    end

    it 'HDR JPEG付き下書きを監査付きで保存し、レシート用利用回数と解析を増やさない' do
      post admin_announcements_path, params: {
        announcement: {
          title: '画像互換性の確認', body: '合成画像のテストです。', kind: 'general',
          image: uploaded_hdr, image_alt_text: '合成HDR画像'
        }
      }

      announcement = Announcement.sole
      aggregate_failures do
        expect(response).to redirect_to(admin_announcement_path(announcement))
        expect(announcement.status).to eq('draft')
        expect_original_hdr(announcement.image)
        expect(AuditLog.where(action: 'announcement.create', actor_user: user).count).to eq(1)
        expect(user.receipts).to be_empty
        expect(usage_counts).to be_empty
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end
  end
end
