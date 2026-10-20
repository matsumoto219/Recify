require 'rails_helper'
require 'tmpdir'

RSpec.describe 'HEIF upload scope', type: :request do
  let(:user) { create(:user) }
  let(:original_bytes) { File.binread(Rails.root.join('spec/fixtures/files/receipt_sample.jpg')) }

  around do |example|
    Dir.mktmpdir('recify-heif-upload-scope-spec') do |directory|
      @service = ActiveStorage::Service::DiskService.new(root: directory)
      @service.name = 'test'
      example.run
    end
  end

  before do
    allow(ActiveStorage::Blob).to receive(:service).and_return(@service)
    allow(ActiveStorage::Blob.services).to receive(:fetch).with('test').and_return(@service)
    expect(ReceiptOcrJob).not_to receive(:perform_later)
    expect(ReceiptOcrService).not_to receive(:call)
    expect(ReceiptAiEnrichmentService).not_to receive(:call)
    sign_in user
  end

  def original_image
    Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/receipt_sample.jpg'), 'image/jpeg')
  end

  def with_heix_upload
    variants = JSON.parse(File.read(Rails.root.join('spec/fixtures/files/heif_image_variants.json')))
    Tempfile.create([ 'synthetic-image', '.heic' ]) do |file|
      file.binmode
      file.write(Base64.strict_decode64(variants.fetch('heix_10')))
      file.rewind
      yield Rack::Test::UploadedFile.new(file.path, 'image/heic')
    end
  end

  def expect_original_image(attachment, old_blob)
    aggregate_failures do
      expect(attachment.blob).to eq(old_blob)
      expect(attachment.blob.content_type).to eq('image/jpeg')
      expect(attachment.download).to eq(original_bytes)
      expect(ActiveStorage::Blob.pluck(:id)).to eq([ old_blob.id ])
      expect(ActiveStorage::Attachment.count).to eq(1)
      expect(UsageCounter.where(user: user)).to be_empty
      expect(ReceiptAnalysisRun.count).to eq(0)
      expect(@service).not_to have_received(:upload)
    end
  end

  it 'HEIF識別後もプロフィールの許可形式を広げず、旧画像と容量を維持する' do
    user.avatar.attach(original_image)
    old_blob = user.avatar.blob
    storage_bytes = user.reload.storage_used_bytes
    allow(@service).to receive(:upload).and_call_original

    with_heix_upload do |image|
      patch user_registration_path, params: {
        update_context: 'account',
        user: { avatar: image }
      }
    end

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('activerecord.errors.models.user.attributes.avatar.invalid_content_type'))
      expect(user.reload.storage_used_bytes).to eq(storage_bytes)
    end
    expect_original_image(user.avatar, old_blob)
  end

  context 'adminのお知らせ画像' do
    let(:user) { create(:user, :admin) }

    it 'HEIF識別後もお知らせの許可形式を広げず、旧画像と成功監査の条件を維持する' do
      announcement = create(:announcement, image_alt_text: '既存画像')
      announcement.image.attach(original_image)
      old_blob = announcement.image.blob
      allow(@service).to receive(:upload).and_call_original

      with_heix_upload do |image|
        patch admin_announcement_path(announcement), params: {
          announcement: { image: image, image_alt_text: '差し替え画像' }
        }
      end

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('activerecord.errors.models.announcement.attributes.image.invalid_content_type'))
        expect(announcement.reload.image_alt_text).to eq('既存画像')
        expect(AuditLog.where(action: 'announcement.update', actor_user: user)).to be_empty
      end
      expect_original_image(announcement.image, old_blob)
    end
  end
end
