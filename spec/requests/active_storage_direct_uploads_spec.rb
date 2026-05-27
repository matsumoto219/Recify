require 'rails_helper'

RSpec.describe 'ActiveStorage direct uploads', type: :request do
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

  it 'rejects unauthenticated direct upload creation' do
    expect do
      post '/rails/active_storage/direct_uploads',
           params: direct_upload_params,
           as: :json
    end.not_to change(ActiveStorage::Blob, :count)

    expect(response).to have_http_status(:not_found)
  end

  it 'rejects authenticated direct upload creation' do
    sign_in create(:user)

    expect do
      post '/rails/active_storage/direct_uploads',
           params: direct_upload_params,
           as: :json
    end.not_to change(ActiveStorage::Blob, :count)

    expect(response).to have_http_status(:not_found)
  end

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
