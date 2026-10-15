require 'rails_helper'
require 'tmpdir'

RSpec.describe 'Receipt image replacement storage failure', type: :request do
  around do |example|
    Dir.mktmpdir('recify-receipt-replacement-spec') do |directory|
      @service = ActiveStorage::Service::DiskService.new(root: directory)
      @service.name = 'test'
      example.run
    end
  end

  before do
    allow(ActiveStorage::Blob).to receive(:service).and_return(@service)
    allow(ActiveStorage::Blob.services).to receive(:fetch).with('test').and_return(@service)
  end

  it '本体保存失敗の422でも旧画像previewと容量控除を保ち、テキスト入力を戻す' do
    user = create(:user)
    receipt = create(:receipt, :completed, :with_image, user: user, memo: 'before')
    original_blob = receipt.image.blob
    original_body = original_blob.download
    uploaded_blob = nil
    sign_in user
    allow(@service).to receive(:upload).and_wrap_original do |method, key, io, **options|
      uploaded_blob = ActiveStorage::Blob.find_by!(key: key)
      method.call(key, io, **options)
      raise Errno::ENOSPC
    end

    patch receipt_path(receipt), params: {
      receipt: {
        lock_version: receipt.lock_version,
        memo: 'after',
        image: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/receipt_sample.jpg'), 'image/jpeg')
      }
    }

    document = Nokogiri::HTML(response.body)
    card = document.at_css('[data-controller~="receipt-image-card"]')
    preview = card&.at_css('img[data-receipt-image-card-target="previewImage"]')
    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('activerecord.errors.models.receipt.attributes.image.upload_failed'))
      expect(preview&.[]('src')).to include(original_blob.signed_id)
      expect(card&.[]('data-receipt-image-card-storage-excluding-blob-bytes-value')).to eq(original_blob.byte_size.to_s)
      expect(document.at_css('textarea[name="receipt[memo]"]')&.text&.delete_prefix("\n")).to eq('after')
      expect(receipt.reload.memo).to eq('before')
      expect(receipt.image.blob).to eq(original_blob)
      expect(original_blob.download).to eq(original_body)
      expect(uploaded_blob).to be_present
      expect(ActiveStorage::Blob.exists?(uploaded_blob&.id)).to be(false)
      expect(user.notifications.where(kind: 'receipt_upload_failed')).to be_empty
    end
    expect(@service.exist?(uploaded_blob.key)).to be(false)
  end
end
