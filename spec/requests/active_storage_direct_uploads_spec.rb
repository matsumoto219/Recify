require 'rails_helper'

RSpec.describe 'ActiveStorage direct uploads', type: :request do
  around do |example|
    original_enabled = Rack::Attack.enabled
    original_store = Rack::Attack.cache.store

    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.reset!

    example.run
  ensure
    Rack::Attack.reset!
    Rack::Attack.cache.store = original_store
    Rack::Attack.enabled = original_enabled
  end

  let(:direct_upload_params) do
    {
      blob: {
        filename: 'receipt.jpg',
        byte_size: 1024,
        checksum: Base64.strict_encode64(Digest::MD5.digest('x' * 1024)),
        content_type: 'image/jpeg'
      }
    }
  end

  def expect_direct_upload_probe_blocked
    aggregate_failures do
      expect(response).to have_http_status(:forbidden)
      expect(response.media_type).to eq('application/json')
      expect(response.parsed_body).to include(
        'error' => I18n.t('errors.forbidden.title'),
        'message' => I18n.t('errors.forbidden.description'),
        'status' => 403
      )
      expect(response.body).not_to include('blob_key')
      expect(response.body).not_to include('signed_id')
      expect(response.body).not_to include('direct_upload_probe')
    end
  end

  it 'blocks unauthenticated direct upload creation as a Rack::Attack probe' do
    expect do
      post '/rails/active_storage/direct_uploads',
           params: direct_upload_params,
           as: :json
    end.not_to change(ActiveStorage::Blob, :count)

    expect_direct_upload_probe_blocked
  end

  it 'blocks authenticated direct upload creation as a Rack::Attack probe' do
    sign_in create(:user)

    expect do
      post '/rails/active_storage/direct_uploads',
           params: direct_upload_params,
           as: :json
    end.not_to change(ActiveStorage::Blob, :count)

    expect_direct_upload_probe_blocked
  end

  # If ActiveStorage direct uploads are intentionally enabled in the future,
  # remove the Rack::Attack direct upload probe rule and update these expectations.

  it 'keeps normal receipt uploads on the application upload endpoint' do
    user = create(:user)
    sign_in user
    allow(ExternalServiceStatus).to receive(:down?).with(:ocr).and_return(false)
    allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
    allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
    allow(ReceiptOcrJob).to receive(:perform_later)

    image = Rack::Test::UploadedFile.new(
      Rails.root.join('spec/fixtures/files/receipt_sample.jpg'),
      'image/jpeg'
    )

    expect do
      post upload_receipts_path, params: { receipt: { image: image } }
    end.to change(Receipt, :count).by(1)

    expect(response).to redirect_to(receipts_path)
    expect(ReceiptOcrJob).to have_received(:perform_later).once
  end
end
