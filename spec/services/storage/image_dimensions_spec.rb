require 'rails_helper'

RSpec.describe Storage::ImageDimensions do
  describe '.extract' do
    it 'blob metadataの画像サイズを返す' do
      blob = instance_double(
        ActiveStorage::Blob,
        metadata: { 'width' => 640, 'height' => 480 }
      )

      expect(described_class.extract(blob: blob)).to eq(width: 640, height: 480)
    end

    it 'metadataの画像サイズが不正ならnilを返す' do
      blob = instance_double(
        ActiveStorage::Blob,
        metadata: { 'width' => 0, 'height' => 480 },
        content_type: 'image/png',
        persisted?: false
      )

      expect(described_class.extract(blob: blob)).to be_nil
    end
  end
end
