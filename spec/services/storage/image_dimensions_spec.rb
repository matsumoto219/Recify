require 'rails_helper'
require 'zlib'

RSpec.describe Storage::ImageDimensions do
  def png_bytes(width:, height:)
    chunk = lambda do |type, data|
      [ data.bytesize ].pack('N') + type + data + [ Zlib.crc32(type + data) ].pack('N')
    end
    header = [ width, height, 8, 2, 0, 0, 0 ].pack('NNCCCCC')
    row = "\x00".b + ("\xFF\xFF\xFF".b * width)
    compressed = Zlib::Deflate.deflate(row * height)

    "\x89PNG\r\n\x1A\n".b +
      chunk.call('IHDR'.b, header) +
      chunk.call('IDAT'.b, compressed) +
      chunk.call('IEND'.b, ''.b)
  end

  def uint24_le(value)
    [ value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF ].pack('C3')
  end

  def webp_vp8x_bytes(width:, height:)
    payload = "\0\0\0\0".b + uint24_le(width - 1) + uint24_le(height - 1)

    "RIFF".b +
      [ 4 + 8 + payload.bytesize ].pack('V') +
      "WEBP".b +
      "VP8X".b +
      [ payload.bytesize ].pack('V') +
      payload
  end

  def blob_for(content_type:, metadata: {})
    instance_double(
      ActiveStorage::Blob,
      content_type: content_type,
      metadata: metadata,
      persisted?: false
    )
  end

  def attached_change_for(bytes)
    instance_double(
      ActiveStorage::Attached::Changes::CreateOne,
      attachable: { io: StringIO.new(bytes) }
    )
  end

  it 'PNGバイナリからdimensionを抽出する' do
    blob = blob_for(content_type: 'image/png')
    attached_change = attached_change_for(png_bytes(width: 120, height: 160))

    expect(described_class.extract(blob: blob, attached_change: attached_change)).to eq(width: 120, height: 160)
  end

  it 'WebPバイナリからdimensionを抽出する' do
    blob = blob_for(content_type: 'image/webp')
    attached_change = attached_change_for(webp_vp8x_bytes(width: 320, height: 240))

    expect(described_class.extract(blob: blob, attached_change: attached_change)).to eq(width: 320, height: 240)
  end

  it 'JPEGとして申告されたテキスト/HTML/JSはdimensionなしとして扱う' do
    bodies = [
      'plain text receipt',
      '<html><body>not an image</body></html>',
      'alert("not an image")'
    ]

    bodies.each do |body|
      blob = blob_for(content_type: 'image/jpeg')
      attached_change = attached_change_for(body)

      expect(described_class.extract(blob: blob, attached_change: attached_change)).to be_nil
    end
  end

  it 'JPEGとして申告されたPDFはdimensionなしとして扱う' do
    blob = blob_for(content_type: 'image/jpeg')
    attached_change = attached_change_for("%PDF-1.7\nnot a receipt image")

    expect(described_class.extract(blob: blob, attached_change: attached_change)).to be_nil
  end

  it 'PNGとして申告されたSVGはdimensionなしとして扱う' do
    blob = blob_for(content_type: 'image/png')
    attached_change = attached_change_for('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>')

    expect(described_class.extract(blob: blob, attached_change: attached_change)).to be_nil
  end

  it 'WebPとして申告された非画像はdimensionなしとして扱う' do
    blob = blob_for(content_type: 'image/webp')
    attached_change = attached_change_for('not a webp image')

    expect(described_class.extract(blob: blob, attached_change: attached_change)).to be_nil
  end
end
