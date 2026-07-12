require 'rails_helper'

RSpec.describe Recify::ActiveStorageLogRedactor do
  it 'Active Storage blob redirect URLをredactする' do
    message = 'Started GET "/rails/active_storage/blobs/redirect/signed-id/file.png" for 127.0.0.1'

    expect(described_class.redact(message)).to eq(
      'Started GET "[FILTERED_ACTIVE_STORAGE_URL]" for 127.0.0.1'
    )
  end

  it 'Active Storage disk URLをhost付きでもredactする' do
    message = 'Redirected to http://localhost:3000/rails/active_storage/disk/encoded-key/file.png'

    expect(described_class.redact(message)).to eq(
      'Redirected to [FILTERED_ACTIVE_STORAGE_URL]'
    )
  end

  it 'Active Storage representation URLをredactする' do
    message = 'path=/rails/active_storage/representations/redirect/signed-id/variation-key/preview.png'

    expect(described_class.redact(message)).to eq(
      'path=[FILTERED_ACTIVE_STORAGE_URL]'
    )
  end

  it 'Active Storage direct upload endpointはredact対象にしない' do
    message = 'Started POST "/rails/active_storage/direct_uploads" for 127.0.0.1'

    expect(described_class.redact(message)).to eq(message)
  end

  it 'nilはnilのまま返す' do
    expect(described_class.redact(nil)).to be_nil
  end
end
