require 'rails_helper'

RSpec.describe Storage::PreparedImages do
  let(:user) { create(:user) }
  let(:receipt) { user.receipts.new(status: 'processing') }

  def core_bmp_bytes(width: 120, height: 160)
    pixels = "\0".b * (((width * 24 + 31) / 32) * 4 * height)
    "BM".b + [ 26 + pixels.bytesize, 0, 0, 26, 12, width, height, 1, 24 ].pack('VvvVVvvvv') + pixels
  end

  def prepare(bytes, content_type:)
    receipt.image = { io: StringIO.new(bytes), filename: 'synthetic', content_type: content_type }
    described_class.call(records: [ receipt ], attachment_name: :image, user: user) { receipt.save! }
  end

  %w[big little].each do |endian|
    it "#{endian} endian BigTIFFの元画像と正しい寸法を保存する" do
      bytes = File.binread(Rails.root.join("spec/fixtures/files/big_tiff_#{endian}.tiff"))

      expect(prepare(bytes, content_type: 'image/tiff')).to be(true)
      blob = receipt.reload.image.blob
      expect(blob.content_type).to eq('image/tiff')
      expect(blob.metadata).to include('width' => 120, 'height' => 160, 'analyzed' => true)
      expect(blob.download).to eq(bytes)
    end
  end

  it 'BMP COREの元画像と16-bit寸法を保存する' do
    bytes = core_bmp_bytes

    expect(prepare(bytes, content_type: 'image/bmp')).to be(true)
    blob = receipt.reload.image.blob
    expect(blob.content_type).to eq('image/bmp')
    expect(blob.metadata).to include('width' => 120, 'height' => 160, 'analyzed' => true)
    expect(blob.download).to eq(bytes)
  end

  it 'BMP COREの最小寸法100pxを受け付ける' do
    bytes = core_bmp_bytes(width: 100, height: 100)

    expect(prepare(bytes, content_type: 'image/bmp')).to be(true)
    expect(receipt.reload.image.blob.metadata).to include('width' => 100, 'height' => 100)
  end

  it 'BMP COREが100px未満なら本体もBlobも保存しない' do
    expect(ActiveStorage::Blob.service).not_to receive(:upload)

    expect(prepare(core_bmp_bytes(width: 99), content_type: 'image/bmp')).to be(false)
    expect(receipt.errors).to be_of_kind(:image, :image_too_small)
    expect(ActiveStorage::Blob.count).to eq(0)
    expect(user.receipts.count).to eq(0)
  end

  it '不完全なBMP headerでは本体もBlobも保存しない' do
    expect(ActiveStorage::Blob.service).not_to receive(:upload)

    expect(prepare(core_bmp_bytes.byteslice(0, 25), content_type: 'image/bmp')).to be(false)
    expect(receipt.errors).to be_of_kind(:image, :invalid_content_type)
    expect(ActiveStorage::Blob.count).to eq(0)
    expect(user.receipts.count).to eq(0)
  end

  it '不正なBigTIFF headerでは本体もBlobも保存しない' do
    bytes = File.binread(Rails.root.join('spec/fixtures/files/big_tiff_little.tiff'))
    bytes[4, 2] = [ 4 ].pack('v')
    expect(ActiveStorage::Blob.service).not_to receive(:upload)

    expect(prepare(bytes, content_type: 'image/tiff')).to be(false)
    expect(receipt.errors).to be_of_kind(:image, :invalid_content_type)
    expect(ActiveStorage::Blob.count).to eq(0)
    expect(user.receipts.count).to eq(0)
  end
end
